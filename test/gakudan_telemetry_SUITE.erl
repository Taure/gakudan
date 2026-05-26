-module(gakudan_telemetry_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    run_emits_start_and_stop/1,
    turn_emits_start_and_stop/1,
    llm_request_span_emits_tokens/1,
    router_decide_span_emits/1,
    tool_run_span_emits/1
]).
-export([forward/4]).

all() ->
    [
        run_emits_start_and_stop,
        turn_emits_start_and_stop,
        llm_request_span_emits_tokens,
        router_decide_span_emits,
        tool_run_span_emits
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(gakudan),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(gakudan),
    ok.

init_per_testcase(Case, Config) ->
    HandlerId = {?MODULE, Case, erlang:unique_integer([positive])},
    Events = [
        [gakudan, run, start],
        [gakudan, run, stop],
        [gakudan, turn, start],
        [gakudan, turn, stop],
        [gakudan, llm, request, start],
        [gakudan, llm, request, stop],
        [gakudan, llm, request, exception],
        [gakudan, router, decide, start],
        [gakudan, router, decide, stop],
        [gakudan, tool, run, start],
        [gakudan, tool, run, stop],
        [gakudan, tool, run, exception]
    ],
    ok = telemetry:attach_many(HandlerId, Events, fun ?MODULE:forward/4, self()),
    [{handler_id, HandlerId} | Config].

end_per_testcase(_Case, Config) ->
    HandlerId = ?config(handler_id, Config),
    telemetry:detach(HandlerId),
    ok.

forward(Event, Measurements, Metadata, Pid) ->
    Pid ! {telemetry, Event, Measurements, Metadata}.

run_emits_start_and_stop(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"hello"}]),
    {ok, _Sup, RunId} = start_run(round_robin, Script),
    ok = gakudan:send(RunId, ~"go"),
    {ok, _} = gakudan:await(RunId, 5000),

    {ok, StartMeasurements, StartMeta} = receive_event([gakudan, run, start], 1000),
    ?assertMatch(#{system_time := _}, StartMeasurements),
    ?assertEqual(RunId, maps:get(run_id, StartMeta)),
    ?assertEqual(gakudan_router_round_robin, maps:get(router, StartMeta)),
    ?assertEqual(gakudan_llm_stub, maps:get(llm_backend, StartMeta)),
    ?assertEqual([agent_a, agent_b], maps:get(agents, StartMeta)),

    ok = gakudan:stop(RunId),
    {ok, StopMeasurements, StopMeta} = receive_event([gakudan, run, stop], 2000),
    ?assertMatch(#{duration := _, turns := _}, StopMeasurements),
    ?assertEqual(RunId, maps:get(run_id, StopMeta)),
    ?assert(maps:get(turns, StopMeasurements) >= 1),
    gen_server:stop(Script).

turn_emits_start_and_stop(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"reply"}]),
    {ok, _Sup, RunId} = start_run(round_robin, Script),
    ok = gakudan:send(RunId, ~"go"),
    {ok, _} = gakudan:await(RunId, 5000),

    {ok, _, StartMeta} = receive_event([gakudan, turn, start], 1000),
    ?assertEqual(RunId, maps:get(run_id, StartMeta)),
    ?assertEqual(agent_a, maps:get(agent_id, StartMeta)),
    ?assertEqual(1, maps:get(turn, StartMeta)),

    {ok, StopMeasurements, StopMeta} = receive_event([gakudan, turn, stop], 1000),
    ?assertMatch(#{duration := _}, StopMeasurements),
    ?assertEqual(ok, maps:get(outcome, StopMeta)),
    ?assertEqual(1, maps:get(turn, StopMeta)),

    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

llm_request_span_emits_tokens(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"hi"}]),
    {ok, _Sup, RunId} = start_run(round_robin, Script),
    ok = gakudan:send(RunId, ~"go"),
    {ok, _} = gakudan:await(RunId, 5000),

    {ok, _, StartMeta} = receive_event([gakudan, llm, request, start], 1000),
    ?assertEqual(RunId, maps:get(run_id, StartMeta)),
    ?assertEqual(gakudan_llm_stub, maps:get(backend, StartMeta)),
    ?assertEqual(~"stub", maps:get(model, StartMeta)),
    ?assertEqual(1, maps:get(turn, StartMeta)),

    {ok, StopMeasurements, StopMeta} = receive_event([gakudan, llm, request, stop], 1000),
    ?assertMatch(#{duration := _, tokens_in := 0, tokens_out := 0}, StopMeasurements),
    ?assertEqual(ok, maps:get(outcome, StopMeta)),

    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

router_decide_span_emits(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"a"}, {text, ~"b"}]),
    {ok, _Sup, RunId} = start_run(round_robin, Script),
    ok = gakudan:send(RunId, ~"go"),
    {ok, _} = gakudan:await(RunId, 5000),

    {ok, _, StartMeta} = receive_event([gakudan, router, decide, start], 1000),
    ?assertEqual(RunId, maps:get(run_id, StartMeta)),
    ?assertEqual(gakudan_router_round_robin, maps:get(router, StartMeta)),

    {ok, _, StopMeta} = receive_event([gakudan, router, decide, stop], 1000),
    ?assertMatch({next, _}, maps:get(decision, StopMeta)),

    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

tool_run_span_emits(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([
        {tool_use, ~"echo_tool", #{~"msg" => ~"hi"}},
        {text, ~"done"}
    ]),
    {ok, _Sup, RunId} = gakudan:start_run(#{
        agents => [agent_with_tool_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => 4
    }),
    ok = gakudan:send(RunId, ~"go"),
    {ok, _} = gakudan:await(RunId, 5000),

    {ok, _, StartMeta} = receive_event([gakudan, tool, run, start], 1000),
    ?assertEqual(RunId, maps:get(run_id, StartMeta)),
    ?assertEqual(~"echo_tool", maps:get(tool, StartMeta)),
    ?assertEqual(1, maps:get(turn, StartMeta)),

    {ok, _, StopMeta} = receive_event([gakudan, tool, run, stop], 1000),
    ?assertEqual(ok, maps:get(outcome, StopMeta)),

    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

start_run(round_robin, Script) ->
    gakudan:start_run(#{
        agents => [agent_a_mod, agent_b_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => 4
    }).

receive_event(Event, Timeout) ->
    receive
        {telemetry, Event, Measurements, Metadata} ->
            {ok, Measurements, Metadata}
    after Timeout ->
        ct:fail({event_not_received, Event})
    end.
