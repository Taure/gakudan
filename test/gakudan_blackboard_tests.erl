-module(gakudan_blackboard_tests).
-include_lib("eunit/include/eunit.hrl").

append_and_read_test() ->
    {ok, Pid} = gakudan_blackboard:start_link(~"run-test-1"),
    {ok, E1} = gakudan_blackboard:append(Pid, user, ~"hello"),
    {ok, E2} = gakudan_blackboard:append(Pid, {agent, planner}, ~"hi"),
    ?assertEqual(1, maps:get(seq, E1)),
    ?assertEqual(2, maps:get(seq, E2)),
    ?assertEqual(user, maps:get(role, E1)),
    ?assertEqual({agent, planner}, maps:get(role, E2)),
    ?assertMatch([_, _], gakudan_blackboard:entries(Pid)),
    gen_server:stop(Pid).

kv_test() ->
    {ok, Pid} = gakudan_blackboard:start_link(~"run-test-2"),
    ?assertEqual({error, not_found}, gakudan_blackboard:get(Pid, foo)),
    ok = gakudan_blackboard:put(Pid, foo, 42),
    ?assertEqual({ok, 42}, gakudan_blackboard:get(Pid, foo)),
    gen_server:stop(Pid).

subscribe_test() ->
    {ok, Pid} = gakudan_blackboard:start_link(~"run-test-3"),
    {ok, _Ref} = gakudan_blackboard:subscribe(Pid),
    {ok, _} = gakudan_blackboard:append(Pid, user, ~"hi"),
    receive
        {gakudan_blackboard, ~"run-test-3", {entry_added, Entry}} ->
            ?assertEqual(~"hi", maps:get(content, Entry))
    after 1000 ->
        ?assert(false)
    end,
    gen_server:stop(Pid).
