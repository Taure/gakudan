-module(gakudan_router_round_robin_tests).
-include_lib("eunit/include/eunit.hrl").

single_round_test() ->
    {ok, S0} = gakudan_router_round_robin:init(#{}, [a, b, c]),
    {next, a, S1} = gakudan_router_round_robin:next(S0, []),
    {next, b, S2} = gakudan_router_round_robin:next(S1, []),
    {next, c, S3} = gakudan_router_round_robin:next(S2, []),
    {done, _} = gakudan_router_round_robin:next(S3, []).

multi_round_test() ->
    {ok, S0} = gakudan_router_round_robin:init(#{rounds => 2}, [a, b]),
    {next, a, S1} = gakudan_router_round_robin:next(S0, []),
    {next, b, S2} = gakudan_router_round_robin:next(S1, []),
    {next, a, S3} = gakudan_router_round_robin:next(S2, []),
    {next, b, S4} = gakudan_router_round_robin:next(S3, []),
    {done, _} = gakudan_router_round_robin:next(S4, []).
