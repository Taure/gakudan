-module(gakudan_run_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    starts_and_stops/1,
    round_robin_two_agents/1,
    handoff_stops_when_no_token/1,
    handoff_follows_agent_mention/1,
    fanout_runs_all_agents/1,
    context_transform_runs_before_turn/1
]).

all() ->
    [
        starts_and_stops,
        round_robin_two_agents,
        handoff_stops_when_no_token,
        handoff_follows_agent_mention,
        fanout_runs_all_agents,
        context_transform_runs_before_turn
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(gakudan),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(gakudan),
    ok.

starts_and_stops(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"hi"}]),
    {ok, _Sup, RunId} = start_run(round_robin, Script),
    {ok, idle} = gakudan:status(RunId),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

round_robin_two_agents(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([
        {text, ~"reply from A"},
        {text, ~"reply from B"}
    ]),
    {ok, _Sup, RunId} = start_run(round_robin, Script),
    ok = gakudan:send(RunId, ~"start"),
    {ok, Entries} = gakudan:await(RunId, 5000),
    Roles = [maps:get(role, E) || E <- Entries],
    AgentRoles = [R || {agent, _} = R <- Roles],
    [{agent, agent_a}, {agent, agent_b}] = AgentRoles,
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

handoff_stops_when_no_token(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([
        {text, ~"reply with no handoff"}
    ]),
    {ok, _Sup, RunId} = start_run(handoff_from_a, Script),
    ok = gakudan:send(RunId, ~"start"),
    {ok, Entries} = gakudan:await(RunId, 5000),
    AgentRoles = [R || #{role := {agent, _} = R} <- Entries],
    [{agent, agent_a}] = AgentRoles,
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

handoff_follows_agent_mention(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([
        {text, ~"plan complete. @agent_b please continue"},
        {text, ~"acknowledged. nothing left to do."}
    ]),
    {ok, _Sup, RunId} = start_run(handoff_from_a, Script),
    ok = gakudan:send(RunId, ~"start"),
    {ok, Entries} = gakudan:await(RunId, 5000),
    AgentRoles = [R || #{role := {agent, _} = R} <- Entries],
    [{agent, agent_a}, {agent, agent_b}] = AgentRoles,
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

fanout_runs_all_agents(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([
        {text, ~"reply one"},
        {text, ~"reply two"}
    ]),
    {ok, _Sup, RunId} = start_run(fanout, Script),
    ok = gakudan:send(RunId, ~"start"),
    {ok, Entries} = gakudan:await(RunId, 5000),
    AgentRoles = lists:sort([R || #{role := {agent, _} = R} <- Entries]),
    [{agent, agent_a}, {agent, agent_b}] = AgentRoles,
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

context_transform_runs_before_turn(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"ok"}]),
    Self = self(),
    {ok, _Sup, RunId} = gakudan:start_run(#{
        agents => [agent_a_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        context => {recording_context_mod, #{notify => Self, keep => 1}},
        max_turns => 1
    }),
    ok = gakudan:send(RunId, ~"hello"),
    {ok, _Entries} = gakudan:await(RunId, 5000),
    receive
        {context_compacted, N} ->
            true = N >= 1
    after 2000 ->
        ct:fail(context_hook_not_invoked)
    end,
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

start_run(Routing, Script) ->
    Router =
        case Routing of
            round_robin -> {gakudan_router_round_robin, #{}};
            handoff_from_a -> {gakudan_router_handoff, #{start => agent_a}};
            fanout -> {gakudan_router_fanout, #{}}
        end,
    gakudan:start_run(#{
        agents => [agent_a_mod, agent_b_mod],
        router => Router,
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => 4
    }).
