-module(gakudan_structured_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    valid_structured_output_is_exposed/1,
    invalid_structured_output_records_failure/1,
    structured_output_from_json_text/1,
    fanout_keeps_every_reviewers_finding/1
]).

all() ->
    [
        valid_structured_output_is_exposed,
        invalid_structured_output_records_failure,
        structured_output_from_json_text,
        fanout_keeps_every_reviewers_finding
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(gakudan),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(gakudan),
    ok.

valid_structured_output_is_exposed(_Config) ->
    Name = gakudan_llm_anthropic:structured_output_tool_name(),
    {ok, Script} = gakudan_llm_stub_script:start_link([
        {tool_use, Name, #{~"score" => 8, ~"summary" => ~"solid"}}
    ]),
    {ok, _Sup, RunId} = start_run(Script),
    ok = gakudan:send(RunId, ~"review"),
    {ok, Entries} = gakudan:await(RunId, 5000),
    {ok, Findings} = gakudan:structured_outputs(RunId),
    ?assertEqual(#{agent_s => #{~"score" => 8, ~"summary" => ~"solid"}}, Findings),
    AgentTexts = [C || #{role := {agent, agent_s}, content := C} <- Entries],
    ?assertMatch([_ | _], AgentTexts),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

invalid_structured_output_records_failure(_Config) ->
    Name = gakudan_llm_anthropic:structured_output_tool_name(),
    {ok, Script} = gakudan_llm_stub_script:start_link([
        {tool_use, Name, #{~"score" => ~"not-an-int"}}
    ]),
    {ok, _Sup, RunId} = start_run(Script),
    ok = gakudan:send(RunId, ~"review"),
    {ok, Entries} = gakudan:await(RunId, 5000),
    {ok, BB} = gakudan_run:blackboard(RunId),
    ?assertEqual({error, not_found}, gakudan_blackboard:get(BB, structured_output)),
    SystemTexts = [C || #{role := system, content := C} <- Entries],
    ?assert(
        lists:any(
            fun(C) -> binary:match(C, ~"failed validation") =/= nomatch end,
            SystemTexts
        )
    ),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

structured_output_from_json_text(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([
        {text, ~"{\"score\":5,\"summary\":\"ok\"}"}
    ]),
    {ok, _Sup, RunId} = start_run(Script),
    ok = gakudan:send(RunId, ~"review"),
    {ok, _Entries} = gakudan:await(RunId, 5000),
    {ok, Findings} = gakudan:structured_outputs(RunId),
    ?assertEqual(#{agent_s => #{~"score" => 5, ~"summary" => ~"ok"}}, Findings),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

fanout_keeps_every_reviewers_finding(_Config) ->
    Name = gakudan_llm_anthropic:structured_output_tool_name(),
    {ok, Script} = gakudan_llm_stub_script:start_link([
        {tool_use, Name, #{~"score" => 9, ~"summary" => ~"from a"}},
        {tool_use, Name, #{~"score" => 2, ~"summary" => ~"from b"}}
    ]),
    {ok, _Sup, RunId} = gakudan:start_run(#{
        agents => [agent_reviewer_a_mod, agent_reviewer_b_mod],
        router => {gakudan_router_fanout, #{rounds => 1}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => 2
    }),
    ok = gakudan:send(RunId, ~"review this"),
    {ok, _} = gakudan:await(RunId, 5000),

    %% The whole point of a review swarm: N reviewers, N findings. A single
    %% fixed blackboard key meant the last writer won and the rest vanished.
    {ok, Findings} = gakudan:structured_outputs(RunId),
    ?assertEqual([reviewer_a, reviewer_b], lists:sort(maps:keys(Findings))),
    ?assertNotEqual(maps:get(reviewer_a, Findings), maps:get(reviewer_b, Findings)),

    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

start_run(Script) ->
    gakudan:start_run(#{
        agents => [agent_structured_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => 2
    }).
