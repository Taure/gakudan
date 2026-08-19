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

structured_outputs_are_kept_per_agent_test() ->
    {ok, Pid} = gakudan_blackboard:start_link(~"run-test-so-1"),
    ?assertEqual(#{}, gakudan_blackboard:structured_outputs(Pid)),

    ok = gakudan_blackboard:put(Pid, {structured_output, reviewer_a}, #{~"sev" => ~"high"}),
    ok = gakudan_blackboard:put(Pid, {structured_output, reviewer_b}, #{~"sev" => ~"low"}),

    %% A fanout of N reviewers must yield N findings, not one survivor.
    ?assertEqual(
        #{reviewer_a => #{~"sev" => ~"high"}, reviewer_b => #{~"sev" => ~"low"}},
        gakudan_blackboard:structured_outputs(Pid)
    ),
    gen_server:stop(Pid).

structured_outputs_ignore_other_kv_keys_test() ->
    {ok, Pid} = gakudan_blackboard:start_link(~"run-test-so-2"),
    ok = gakudan_blackboard:put(Pid, some_other_key, ~"not a finding"),
    ok = gakudan_blackboard:put(Pid, {structured_output, only_one}, #{~"ok" => true}),
    ?assertEqual(#{only_one => #{~"ok" => true}}, gakudan_blackboard:structured_outputs(Pid)),
    gen_server:stop(Pid).

structured_output_survives_snapshot_restore_test() ->
    {ok, A} = gakudan_blackboard:start_link(~"run-test-so-3"),
    ok = gakudan_blackboard:put(A, {structured_output, reviewer_a}, #{~"sev" => ~"high"}),
    Snap = gakudan_blackboard:snapshot(A),
    gen_server:stop(A),

    %% Tuple-keyed kv has to round-trip through the checkpointer, or a resumed
    %% run loses every finding it had already collected.
    {ok, B} = gakudan_blackboard:start_link(~"run-test-so-4"),
    ok = gakudan_blackboard:restore(B, Snap),
    ?assertEqual(#{reviewer_a => #{~"sev" => ~"high"}}, gakudan_blackboard:structured_outputs(B)),
    gen_server:stop(B).

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
