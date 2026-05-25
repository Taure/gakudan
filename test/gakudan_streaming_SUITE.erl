-module(gakudan_streaming_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    subscriber_receives_text_delta/1,
    subscriber_receives_stream_chunks/1,
    unsubscribe_stops_messages/1,
    fallback_for_non_streaming_backend/1,
    multiple_subscribers_each_get_events/1,
    telemetry_stream_events_fire/1
]).

all() ->
    [
        subscriber_receives_text_delta,
        subscriber_receives_stream_chunks,
        unsubscribe_stops_messages,
        fallback_for_non_streaming_backend,
        multiple_subscribers_each_get_events,
        telemetry_stream_events_fire
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(gakudan),
    Config.

end_per_suite(_Config) ->
    application:stop(gakudan),
    ok.

subscriber_receives_text_delta(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"hello"}]),
    {ok, _Sup, RunId} = start_run(Script),
    {ok, _Ref} = gakudan:subscribe_stream(RunId),
    ok = gakudan:send(RunId, ~"go"),
    {ok, _} = gakudan:await(RunId, 5000),
    Events = collect_stream_events(RunId, 500),
    Texts = [
        maps:get(payload, M)
     || #{payload := {text_delta, _}} = M <- Events
    ],
    true = lists:any(fun({text_delta, T}) -> T =:= ~"hello" end, Texts),
    cleanup(Script, RunId).

subscriber_receives_stream_chunks(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([
        {stream_chunks, [~"hel", ~"lo ", ~"world"]}
    ]),
    {ok, _Sup, RunId} = start_run(Script),
    {ok, _Ref} = gakudan:subscribe_stream(RunId),
    ok = gakudan:send(RunId, ~"go"),
    {ok, _} = gakudan:await(RunId, 5000),
    Events = collect_stream_events(RunId, 500),
    TextDeltas = [
        Delta
     || #{payload := {text_delta, Delta}} <- Events
    ],
    [~"hel", ~"lo ", ~"world"] = TextDeltas,
    cleanup(Script, RunId).

unsubscribe_stops_messages(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([
        {stream_chunks, [~"a", ~"b", ~"c"]},
        {stream_chunks, [~"d", ~"e", ~"f"]}
    ]),
    {ok, _Sup, RunId} = start_run(Script),
    {ok, Ref} = gakudan:subscribe_stream(RunId),
    ok = gakudan:send(RunId, ~"go"),
    timer:sleep(200),
    ok = gakudan:unsubscribe_stream(RunId, Ref),
    Before = collect_stream_events(RunId, 100),
    {ok, _} = gakudan:await(RunId, 2000),
    %% drain any further events (should be none after unsubscribe)
    After = collect_stream_events(RunId, 100),
    true = length(Before) > 0,
    [] = After,
    cleanup(Script, RunId).

fallback_for_non_streaming_backend(_Config) ->
    {ok, _Sup, RunId} = gakudan:start_run(#{
        agents => [agent_a_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {non_streaming_stub, #{response_text => ~"from fallback"}},
        max_turns => 1
    }),
    {ok, _Ref} = gakudan:subscribe_stream(RunId),
    ok = gakudan:send(RunId, ~"go"),
    {ok, _} = gakudan:await(RunId, 5000),
    Events = collect_stream_events(RunId, 500),
    HasDelta = lists:any(
        fun
            (#{payload := {text_delta, ~"from fallback"}}) -> true;
            (_) -> false
        end,
        Events
    ),
    true = HasDelta,
    ok = gakudan:stop(RunId).

multiple_subscribers_each_get_events(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"hi"}]),
    {ok, _Sup, RunId} = start_run(Script),
    Self = self(),
    Sub1 = spawn_link(fun() -> sub_loop(Self, sub1, RunId) end),
    Sub2 = spawn_link(fun() -> sub_loop(Self, sub2, RunId) end),
    ok = wait_subbed(2),
    ok = gakudan:send(RunId, ~"go"),
    {ok, _} = gakudan:await(RunId, 5000),
    timer:sleep(100),
    Sub1 ! report,
    Sub2 ! report,
    Reports = receive_reports(2, []),
    true =
        lists:all(
            fun({_Tag, Events}) -> length(Events) >= 2 end,
            Reports
        ),
    cleanup(Script, RunId).

telemetry_stream_events_fire(_Config) ->
    Self = self(),
    telemetry:attach_many(
        ?MODULE,
        [
            [gakudan, llm, stream, start],
            [gakudan, llm, stream, token],
            [gakudan, llm, stream, complete]
        ],
        fun(Name, Meas, Meta, _Cfg) -> Self ! {tel, Name, Meas, Meta} end,
        undefined
    ),
    {ok, Script} = gakudan_llm_stub_script:start_link([
        {stream_chunks, [~"a", ~"b"]}
    ]),
    {ok, _Sup, RunId} = start_run(Script),
    ok = gakudan:send(RunId, ~"go"),
    {ok, _} = gakudan:await(RunId, 5000),
    Events = collect_telemetry(300),
    StartEvents = [N || {N, _, _} <- Events, N =:= [gakudan, llm, stream, start]],
    TokenEvents = [N || {N, _, _} <- Events, N =:= [gakudan, llm, stream, token]],
    CompleteEvents = [N || {N, _, _} <- Events, N =:= [gakudan, llm, stream, complete]],
    true = length(StartEvents) >= 1,
    true = length(TokenEvents) >= 2,
    true = length(CompleteEvents) >= 1,
    telemetry:detach(?MODULE),
    cleanup(Script, RunId).

%% helpers

start_run(Script) ->
    gakudan:start_run(#{
        agents => [agent_a_mod, agent_b_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => 1
    }).

cleanup(Script, RunId) ->
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

collect_stream_events(RunId, Timeout) ->
    collect_stream_events(RunId, Timeout, []).

collect_stream_events(RunId, Timeout, Acc) ->
    receive
        {gakudan_stream, RunId, Event} ->
            collect_stream_events(RunId, Timeout, [Event | Acc])
    after Timeout ->
        lists:reverse(Acc)
    end.

collect_telemetry(Timeout) ->
    collect_telemetry(Timeout, []).

collect_telemetry(Timeout, Acc) ->
    receive
        {tel, N, M, Meta} -> collect_telemetry(Timeout, [{N, M, Meta} | Acc])
    after Timeout ->
        lists:reverse(Acc)
    end.

sub_loop(Parent, Tag, RunId) ->
    {ok, _Ref} = gakudan:subscribe_stream(RunId),
    Parent ! {subbed, Tag},
    sub_collect(Parent, Tag, RunId, []).

sub_collect(Parent, Tag, RunId, Acc) ->
    receive
        {gakudan_stream, RunId, Event} ->
            sub_collect(Parent, Tag, RunId, [Event | Acc]);
        report ->
            Parent ! {report, Tag, lists:reverse(Acc)}
    end.

wait_subbed(0) ->
    ok;
wait_subbed(N) ->
    receive
        {subbed, _} -> wait_subbed(N - 1)
    after 1000 ->
        error(subscriber_timeout)
    end.

receive_reports(0, Acc) ->
    Acc;
receive_reports(N, Acc) ->
    receive
        {report, Tag, Events} -> receive_reports(N - 1, [{Tag, Events} | Acc])
    after 2000 ->
        error(report_timeout)
    end.
