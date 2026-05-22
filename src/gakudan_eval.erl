-module(gakudan_eval).
-moduledoc """
Deterministic eval harness for gakudan runs.

Given a case (run config + scripted LLM responses + an input + expectations),
runs the agent collaboration against `gakudan_llm_stub`, collects the
resulting blackboard transcript and the telemetry event stream, and reports
which expectations passed and which failed.

```erlang
{ok, Report} = gakudan_eval:run(#{
    config => #{
        agents => [planner_mod, coder_mod],
        router => {gakudan_router_handoff, #{start => planner}},
        max_turns => 4
    },
    script => [
        {text, ~"Plan: ... @coder please continue."},
        {text, ~"acknowledged."}
    ],
    input => ~"Build me a TCP echo server",
    expect => [
        {outcome, idle},
        {min_turns, 2},
        {agent_turn_contains, planner, ~"Plan"},
        {agent_turn_contains, coder, ~"acknowledged"}
    ]
}).
```

`run/1` returns `{ok, Report}` if every expectation passed and
`{error, Report}` if any failed. `Report` is a map with the transcript, the
collected telemetry events, total duration, and per-expectation pass/fail.
""".

-export([run/1, assert_passed/1]).

-export_type([case_spec/0, expectation/0, report/0]).

-define(DEFAULT_TIMEOUT, 5000).

-type case_spec() :: #{
    name => binary() | atom(),
    config := map(),
    script := [term()],
    input := binary(),
    timeout => timeout(),
    expect := [expectation()]
}.

-type expectation() ::
    {outcome, idle | running | completed}
    | {min_turns, non_neg_integer()}
    | {max_turns, non_neg_integer()}
    | {agent_turn_contains, atom(), binary()}
    | {agent_turn_count, atom(), non_neg_integer()}
    | {tokens_input_at_least, non_neg_integer()}
    | {tokens_output_at_least, non_neg_integer()}
    | {tool_called, binary()}
    | no_failed_turns
    | {transcript_min_length, non_neg_integer()}.

-type telemetry_record() :: {[atom()], map(), map()}.

-type outcome() :: idle | running | completed | initialising | {error, term()}.

-type report() :: #{
    name := binary() | atom(),
    transcript := [gakudan_blackboard:entry()],
    telemetry := [telemetry_record()],
    duration_ms := integer(),
    outcome := outcome(),
    passed := [expectation()],
    failed := [{expectation(), term()}]
}.

-doc "Run a single eval case. Returns `{ok, Report}` if every expectation passed.".
-spec run(case_spec()) -> {ok, report()} | {error, report()}.
run(Case) ->
    Name = maps:get(name, Case, unnamed),
    Timeout = maps:get(timeout, Case, ?DEFAULT_TIMEOUT),
    Expectations = maps:get(expect, Case, []),
    Script = maps:get(script, Case),
    Input = maps:get(input, Case),
    Config = ensure_stub_llm(maps:get(config, Case)),
    HandlerId = {?MODULE, erlang:unique_integer([positive])},
    Self = self(),
    ok = attach_telemetry(HandlerId, Self),
    Start = erlang:monotonic_time(millisecond),
    Result =
        try
            {ok, ScriptPid} = gakudan_llm_stub_script:start_link(Script),
            try
                FullConfig = Config#{llm => {gakudan_llm_stub, #{script_owner => ScriptPid}}},
                {ok, _Sup, RunId} = gakudan:start_run(FullConfig),
                try
                    ok = gakudan:send(RunId, Input),
                    AwaitResult = gakudan:await(RunId, Timeout),
                    {ok, Status} = gakudan:status(RunId),
                    {AwaitResult, Status, RunId}
                after
                    safe_stop_run(RunId)
                end
            after
                safe_stop_script(ScriptPid)
            end
        catch
            Class:Reason:_St -> {harness_error, {Class, Reason}}
        end,
    DurationMs = erlang:monotonic_time(millisecond) - Start,
    TelemetryEvents = collect_telemetry(),
    ok = telemetry:detach(HandlerId),
    {Transcript, Outcome} = unpack_result(Result),
    {Passed, Failed} = evaluate(Expectations, #{
        transcript => Transcript,
        telemetry => TelemetryEvents,
        outcome => Outcome
    }),
    Report = #{
        name => Name,
        transcript => Transcript,
        telemetry => TelemetryEvents,
        duration_ms => DurationMs,
        outcome => Outcome,
        passed => Passed,
        failed => Failed
    },
    case Failed of
        [] -> {ok, Report};
        _ -> {error, Report}
    end.

-doc "Crash with a descriptive reason if the report lists any failures.".
-spec assert_passed({ok | error, report()}) -> ok | no_return().
assert_passed({ok, _Report}) ->
    ok;
assert_passed({error, #{name := Name, failed := Failed}}) ->
    error({eval_failed, Name, Failed}).

ensure_stub_llm(#{llm := _} = Config) ->
    Config;
ensure_stub_llm(Config) ->
    Config.

safe_stop_run(RunId) ->
    try gakudan:stop(RunId) of
        _ -> ok
    catch
        _:_ -> ok
    end.

safe_stop_script(Pid) ->
    try gen_server:stop(Pid) of
        _ -> ok
    catch
        _:_ -> ok
    end.

attach_telemetry(HandlerId, Pid) ->
    Events = [
        [gakudan, run, start],
        [gakudan, run, stop],
        [gakudan, turn, start],
        [gakudan, turn, stop],
        [gakudan, llm, request, start],
        [gakudan, llm, request, stop],
        [gakudan, llm, request, exception],
        [gakudan, tool, run, start],
        [gakudan, tool, run, stop],
        [gakudan, tool, run, exception],
        [gakudan, router, decide, start],
        [gakudan, router, decide, stop],
        [gakudan, router, decide, exception]
    ],
    telemetry:attach_many(HandlerId, Events, fun forward_event/4, Pid).

forward_event(Event, Measurements, Metadata, Pid) ->
    Pid ! {?MODULE, telemetry, Event, Measurements, Metadata}.

collect_telemetry() ->
    collect_telemetry([]).

collect_telemetry(Acc) ->
    receive
        {?MODULE, telemetry, Event, M, Meta} ->
            collect_telemetry([{Event, M, Meta} | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

unpack_result({{ok, Transcript}, Status, _RunId}) ->
    {Transcript, Status};
unpack_result({{error, Reason}, Status, _RunId}) ->
    {[], {error, {await, Reason, Status}}};
unpack_result({harness_error, Reason}) ->
    {[], {error, {harness, Reason}}}.

evaluate(Expectations, Context) ->
    evaluate(Expectations, Context, [], []).

evaluate([], _Context, Pass, Fail) ->
    {lists:reverse(Pass), lists:reverse(Fail)};
evaluate([Exp | Rest], Context, Pass, Fail) ->
    case check(Exp, Context) of
        ok -> evaluate(Rest, Context, [Exp | Pass], Fail);
        {fail, Reason} -> evaluate(Rest, Context, Pass, [{Exp, Reason} | Fail])
    end.

check({outcome, Expected}, #{outcome := Actual}) ->
    case Actual of
        Expected -> ok;
        _ -> {fail, {expected, Expected, got, Actual}}
    end;
check({min_turns, N}, #{telemetry := Events}) ->
    Actual = count_event(Events, [gakudan, turn, stop]),
    case Actual >= N of
        true -> ok;
        false -> {fail, {turns, Actual, ~"<", N}}
    end;
check({max_turns, N}, #{telemetry := Events}) ->
    Actual = count_event(Events, [gakudan, turn, stop]),
    case Actual =< N of
        true -> ok;
        false -> {fail, {turns, Actual, ~">", N}}
    end;
check({agent_turn_contains, AgentId, Substring}, #{transcript := T}) ->
    case find_agent_text(T, AgentId, Substring) of
        true -> ok;
        false -> {fail, {no_match, AgentId, Substring}}
    end;
check({agent_turn_count, AgentId, N}, #{transcript := T}) ->
    Actual = count_agent_turns(T, AgentId),
    case Actual of
        N -> ok;
        _ -> {fail, {agent, AgentId, expected, N, got, Actual}}
    end;
check({tokens_input_at_least, N}, #{telemetry := Events}) ->
    Actual = sum_measurement(Events, [gakudan, llm, request, stop], tokens_in),
    case Actual >= N of
        true -> ok;
        false -> {fail, {tokens_in, Actual, ~"<", N}}
    end;
check({tokens_output_at_least, N}, #{telemetry := Events}) ->
    Actual = sum_measurement(Events, [gakudan, llm, request, stop], tokens_out),
    case Actual >= N of
        true -> ok;
        false -> {fail, {tokens_out, Actual, ~"<", N}}
    end;
check({tool_called, Name}, #{telemetry := Events}) ->
    case any_event_with(Events, [gakudan, tool, run, stop], #{tool => Name}) of
        true -> ok;
        false -> {fail, {tool_not_called, Name}}
    end;
check(no_failed_turns, #{telemetry := Events}) ->
    case any_event_with(Events, [gakudan, turn, stop], #{outcome => failed}) of
        true -> {fail, has_failed_turns};
        false -> ok
    end;
check({transcript_min_length, N}, #{transcript := T}) ->
    Actual = length(T),
    case Actual >= N of
        true -> ok;
        false -> {fail, {transcript_length, Actual, ~"<", N}}
    end;
check(Other, _Context) ->
    {fail, {unknown_expectation, Other}}.

count_event(Events, Name) ->
    length([1 || {E, _, _} <- Events, E =:= Name]).

sum_measurement(Events, Name, Key) ->
    lists:sum([
        maps:get(Key, M, 0)
     || {E, M, _} <- Events, E =:= Name
    ]).

any_event_with(Events, Name, Match) ->
    lists:any(
        fun({E, _, Meta}) ->
            E =:= Name andalso
                maps:fold(
                    fun(K, V, Acc) -> Acc andalso maps:get(K, Meta, undefined) =:= V end,
                    true,
                    Match
                )
        end,
        Events
    ).

find_agent_text(Transcript, AgentId, Substring) ->
    lists:any(
        fun
            (#{role := {agent, A}, content := C}) when A =:= AgentId, is_binary(C) ->
                binary:match(C, Substring) =/= nomatch;
            (_) ->
                false
        end,
        Transcript
    ).

count_agent_turns(Transcript, AgentId) ->
    length([1 || #{role := {agent, A}} <- Transcript, A =:= AgentId]).
