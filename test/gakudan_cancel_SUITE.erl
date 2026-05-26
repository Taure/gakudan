-module(gakudan_cancel_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    cancel_stops_in_flight_stream/1,
    cancel_idle_run_is_noop/1,
    cancel_during_fanout_goes_idle/1
]).

all() ->
    [cancel_stops_in_flight_stream, cancel_idle_run_is_noop, cancel_during_fanout_goes_idle].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(gakudan),
    Config.

end_per_suite(_Config) ->
    application:stop(gakudan),
    ok.

cancel_stops_in_flight_stream(_Config) ->
    Handler = make_ref(),
    Self = self(),
    ok = telemetry:attach(
        Handler,
        [gakudan, run, cancelled],
        fun(_E, _M, Meta, _) -> Self ! {cancelled, Meta} end,
        undefined
    ),
    %% The stub blocks in stream_call until it receives the cancel signal.
    {ok, Script} = gakudan_llm_stub_script:start_link([block]),
    {ok, _Sup, RunId} = gakudan:start_run(#{
        agents => [agent_a_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => 2
    }),
    ok = gakudan:send(RunId, ~"go"),
    ok = wait_status(RunId, running, 100),
    ok = gakudan:cancel(RunId),
    receive
        {cancelled, #{run_id := RunId}} -> ok
    after 5000 -> ct:fail(no_cancel_telemetry)
    end,
    ok = wait_status(RunId, idle, 100),
    {ok, BB} = gakudan_run:blackboard(RunId),
    Entries = gakudan_blackboard:entries(BB),
    true = has_system_match(Entries, ~"run cancelled"),
    %% No agent output was produced.
    [] = [E || E <- Entries, is_agent(maps:get(role, E))],
    telemetry:detach(Handler),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

cancel_idle_run_is_noop(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"hi"}]),
    {ok, _Sup, RunId} = gakudan:start_run(#{
        agents => [agent_a_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => 1
    }),
    %% Nothing in flight: cancel is a harmless no-op.
    ok = gakudan:cancel(RunId),
    {ok, idle} = gakudan:status(RunId),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

cancel_during_fanout_goes_idle(_Config) ->
    %% Two agents fanned out, both blocked in-flight; one cancel stops both.
    {ok, Script} = gakudan_llm_stub_script:start_link([block, block]),
    {ok, _Sup, RunId} = gakudan:start_run(#{
        agents => [agent_a_mod, agent_b_mod],
        router => {gakudan_router_fanout, #{rounds => 1}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => 4
    }),
    ok = gakudan:send(RunId, ~"go"),
    ok = wait_status(RunId, running, 100),
    ok = gakudan:cancel(RunId),
    ok = wait_status(RunId, idle, 100),
    {ok, BB} = gakudan_run:blackboard(RunId),
    true = has_system_match(gakudan_blackboard:entries(BB), ~"run cancelled"),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

wait_status(_RunId, _Target, 0) ->
    ct:fail(status_timeout);
wait_status(RunId, Target, N) ->
    case gakudan:status(RunId) of
        {ok, Target} ->
            ok;
        _ ->
            timer:sleep(20),
            wait_status(RunId, Target, N - 1)
    end.

has_system_match(Entries, Substr) ->
    lists:any(
        fun(E) ->
            maps:get(role, E) =:= system andalso
                binary:match(maps:get(content, E), Substr) =/= nomatch
        end,
        Entries
    ).

is_agent({agent, _}) -> true;
is_agent(_) -> false.
