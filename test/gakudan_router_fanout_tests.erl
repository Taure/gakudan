-module(gakudan_router_fanout_tests).
-include_lib("eunit/include/eunit.hrl").

single_round_test() ->
    {ok, S0} = gakudan_router_fanout:init(#{}, [a, b, c]),
    {fanout, [a, b, c], S1} = gakudan_router_fanout:next(S0, []),
    {done, _} = gakudan_router_fanout:next(S1, []).

multi_round_test() ->
    {ok, S0} = gakudan_router_fanout:init(#{rounds => 2}, [a, b]),
    {fanout, [a, b], S1} = gakudan_router_fanout:next(S0, []),
    {fanout, [a, b], S2} = gakudan_router_fanout:next(S1, []),
    {done, _} = gakudan_router_fanout:next(S2, []).

zero_rounds_is_done_test() ->
    {ok, S0} = gakudan_router_fanout:init(#{rounds => 0}, [a, b]),
    {done, _} = gakudan_router_fanout:next(S0, []).
