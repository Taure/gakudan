-module(gakudan_router_loop_tests).
-include_lib("eunit/include/eunit.hrl").

entry(Agent, Text) ->
    #{seq => 1, role => {agent, Agent}, content => Text, ts => 0}.

single_agent_loops_until_max_test() ->
    {ok, S0} = gakudan_router_loop:init(#{agents => [a], max_iterations => 3}, [a, b]),
    {next, a, S1} = gakudan_router_loop:next(S0, []),
    {next, a, S2} = gakudan_router_loop:next(S1, []),
    {next, a, S3} = gakudan_router_loop:next(S2, []),
    {done, _} = gakudan_router_loop:next(S3, []).

cycles_agent_list_test() ->
    {ok, S0} = gakudan_router_loop:init(#{agents => [a, b], max_iterations => 4}, [a, b]),
    {next, a, S1} = gakudan_router_loop:next(S0, []),
    {next, b, S2} = gakudan_router_loop:next(S1, []),
    {next, a, S3} = gakudan_router_loop:next(S2, []),
    {next, b, S4} = gakudan_router_loop:next(S3, []),
    {done, _} = gakudan_router_loop:next(S4, []).

until_predicate_stops_loop_test() ->
    Until = fun(Transcript) ->
        lists:any(
            fun(#{content := C}) -> binary:match(C, ~"DONE") =/= nomatch end,
            Transcript
        )
    end,
    {ok, S0} = gakudan_router_loop:init(#{agents => [a], until => Until}, [a]),
    {next, a, S1} = gakudan_router_loop:next(S0, []),
    %% Not done yet.
    {next, a, S2} = gakudan_router_loop:next(S1, [entry(a, ~"still working")]),
    %% Predicate now satisfied.
    {done, _} = gakudan_router_loop:next(S2, [entry(a, ~"all DONE")]).

defaults_to_all_agents_test() ->
    {ok, S0} = gakudan_router_loop:init(#{max_iterations => 2}, [x, y]),
    {next, x, S1} = gakudan_router_loop:next(S0, []),
    {next, y, _} = gakudan_router_loop:next(S1, []).

bad_agents_rejected_test() ->
    ?assertError(
        {loop_router_bad_agents, _, _},
        gakudan_router_loop:init(#{agents => [z]}, [a, b])
    ).
