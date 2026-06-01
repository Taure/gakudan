-module(gakudan_fork_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2]).
-export([
    build_snapshot_truncates_to_step/1,
    build_snapshot_unknown_step/1,
    build_snapshot_unknown_run/1,
    fork_starts_new_run_with_history/1,
    fork_without_checkpointer_errors/1
]).

all() ->
    [
        build_snapshot_truncates_to_step,
        build_snapshot_unknown_step,
        build_snapshot_unknown_run,
        fork_starts_new_run_with_history,
        fork_without_checkpointer_errors
    ].

init_per_suite(Config) ->
    Backend = gakudan_checkpointer_ets:new(),
    application:set_env(gakudan, default_checkpointer, {gakudan_checkpointer_ets, Backend}),
    {ok, _} = application:ensure_all_started(gakudan),
    [{backend, Backend} | Config].

end_per_suite(_Config) ->
    application:unset_env(gakudan, default_checkpointer),
    application:stop(gakudan),
    ok.

init_per_testcase(_Name, Config) ->
    Backend = proplists:get_value(backend, Config),
    ok = gakudan_checkpointer_ets:reset(Backend),
    Config.

build_snapshot_truncates_to_step(Config) ->
    {ok, Handle} = handle(Config),
    SrcRunId = ~"src-1",
    Entries = [
        entry(1, user, ~"task"),
        entry(2, {agent, a}, ~"thinking"),
        entry(3, {agent, a}, ~"more"),
        entry(4, {agent, a}, ~"final")
    ],
    ok = gakudan_checkpointer:save_snapshot(Handle, snapshot(SrcRunId, Entries)),
    %% A step whose request saw only the first two entries.
    Step = step(SrcRunId, ~"step-x", [#{role => user}, #{role => assistant}]),
    ok = gakudan_checkpointer:save_step(Handle, Step),

    {ok, Forked} = gakudan_fork:build_snapshot(Handle, {SrcRunId, ~"step-x"}, ~"new-1"),
    ?assertEqual(~"new-1", maps:get(run_id, Forked)),
    ?assertEqual(idle, maps:get(status, Forked)),
    KeptSeqs = [maps:get(seq, E) || E <- maps:get(blackboard, Forked)],
    ?assertEqual([1, 2], KeptSeqs),
    ?assertEqual(~"new-1", maps:get(run_id, maps:get(config, Forked))),
    ?assertEqual(
        #{run_id => SrcRunId, step_id => ~"step-x"},
        maps:get(forked_from, Forked)
    ).

build_snapshot_unknown_step(Config) ->
    {ok, Handle} = handle(Config),
    ok = gakudan_checkpointer:save_snapshot(Handle, snapshot(~"src-2", [])),
    ?assertEqual(
        {error, {step_not_found, ~"nope"}},
        gakudan_fork:build_snapshot(Handle, {~"src-2", ~"nope"}, ~"new-2")
    ).

build_snapshot_unknown_run(Config) ->
    {ok, Handle} = handle(Config),
    ?assertMatch(
        {error, {source_run_not_found, ~"ghost", _}},
        gakudan_fork:build_snapshot(Handle, {~"ghost", ~"s"}, ~"new-3")
    ).

fork_starts_new_run_with_history(Config) ->
    {ok, Handle} = handle(Config),
    SrcRunId = ~"src-run",
    Entries = [
        entry(1, user, ~"original task"),
        entry(2, {agent, agent_a}, ~"partial work")
    ],
    ok = gakudan_checkpointer:save_snapshot(Handle, snapshot(SrcRunId, Entries)),
    Step = step(SrcRunId, ~"fp", [#{role => user}, #{role => assistant}]),
    ok = gakudan_checkpointer:save_step(Handle, Step),

    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"continued"}]),
    {ok, _Sup, NewRunId} = gakudan:start_run(#{
        agents => [agent_a_mod, agent_b_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => 4,
        fork_from => {SrcRunId, ~"fp"}
    }),
    ?assertNotEqual(SrcRunId, NewRunId),
    {ok, BB} = gakudan_run:blackboard(NewRunId),
    Contents = [maps:get(content, E) || E <- gakudan_blackboard:entries(BB)],
    ?assert(lists:member(~"original task", Contents)),
    ?assert(lists:member(~"partial work", Contents)),
    %% Source run untouched (no live process for it).
    ?assertEqual({error, not_found}, gakudan_run:status(SrcRunId)),
    ok = gakudan:stop(NewRunId),
    gen_server:stop(Script).

fork_without_checkpointer_errors(_Config) ->
    application:unset_env(gakudan, default_checkpointer),
    Result = gakudan:start_run(#{
        agents => [agent_a_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{}},
        fork_from => {~"x", ~"y"}
    }),
    ?assertEqual({error, no_checkpointer}, Result).

handle(Config) ->
    Backend = proplists:get_value(backend, Config),
    gakudan_checkpointer:init(gakudan_checkpointer_ets, Backend).

entry(Seq, Role, Content) ->
    #{seq => Seq, role => Role, content => Content, ts => Seq}.

snapshot(RunId, Entries) ->
    #{
        run_id => RunId,
        status => idle,
        config => #{
            run_id => RunId,
            agents => [agent_a_mod, agent_b_mod],
            router => {gakudan_router_round_robin, #{}},
            llm => {gakudan_llm_stub, #{}}
        },
        last_step => 0,
        blackboard => Entries,
        kv => #{},
        router_state => undefined,
        statem_state => idle,
        turn => 1,
        updated_at => erlang:system_time(millisecond)
    }.

step(RunId, StepId, Messages) ->
    #{
        run_id => RunId,
        step_id => StepId,
        agent_id => agent_a,
        turn => 1,
        request => #{model => ~"m", messages => Messages},
        response => #{stop_reason => end_turn},
        usage => #{input_tokens => 0, output_tokens => 0},
        inserted_at => erlang:system_time(millisecond)
    }.
