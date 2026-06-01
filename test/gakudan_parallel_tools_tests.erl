-module(gakudan_parallel_tools_tests).
-include_lib("eunit/include/eunit.hrl").

ctx() ->
    #{
        run_id => ~"r",
        agent_id => a,
        turn => 1,
        checkpointer => undefined
    }.

resolved() ->
    [gakudan_tool:resolve_one(sleepy_tool_mod)].

tool_use(Id, Label, Delay) ->
    #{
        type => tool_use,
        id => Id,
        name => ~"sleepy_tool",
        input => #{~"label" => Label, ~"delay" => Delay}
    }.

empty_test() ->
    ?assertEqual([], gakudan_turn:run_tools(ctx(), 0, resolved(), [])).

single_tool_runs_inline_test() ->
    Uses = [tool_use(~"t1", ~"only", 0)],
    [Block] = gakudan_turn:run_tools(ctx(), 0, resolved(), Uses),
    ?assertEqual(~"t1", maps:get(tool_use_id, Block)),
    ?assertEqual(~"only", maps:get(content, Block)).

parallel_preserves_block_order_test() ->
    %% First block sleeps longest; if results were gathered in completion
    %% order the order would invert. They must come back in block order.
    Uses = [
        tool_use(~"t1", ~"first", 80),
        tool_use(~"t2", ~"second", 10),
        tool_use(~"t3", ~"third", 40)
    ],
    Blocks = gakudan_turn:run_tools(ctx(), 0, resolved(), Uses),
    Ids = [maps:get(tool_use_id, B) || B <- Blocks],
    Labels = [maps:get(content, B) || B <- Blocks],
    ?assertEqual([~"t1", ~"t2", ~"t3"], Ids),
    ?assertEqual([~"first", ~"second", ~"third"], Labels).

parallel_runs_concurrently_test() ->
    %% Three 100ms sleeps finish in ~100ms wall-clock if concurrent, ~300ms
    %% if sequential. Assert well under the sequential time.
    Uses = [
        tool_use(~"t1", ~"a", 100),
        tool_use(~"t2", ~"b", 100),
        tool_use(~"t3", ~"c", 100)
    ],
    {Micros, Blocks} = timer:tc(fun() ->
        gakudan_turn:run_tools(ctx(), 0, resolved(), Uses)
    end),
    ?assertEqual(3, length(Blocks)),
    ?assert(Micros < 250_000).

unknown_tool_is_error_block_test() ->
    Uses = [
        tool_use(~"t1", ~"ok", 0),
        #{type => tool_use, id => ~"t2", name => ~"nope", input => #{}}
    ],
    Blocks = gakudan_turn:run_tools(ctx(), 0, resolved(), Uses),
    [B1, B2] = Blocks,
    ?assertEqual(~"ok", maps:get(content, B1)),
    ?assertEqual(true, maps:get(is_error, B2)).
