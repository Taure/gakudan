-module(gakudan_persistence_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    snapshot_round_trip/1,
    list_active_returns_running_runs/1,
    step_record_round_trip/1,
    interrupt_then_resume/1,
    initial_messages_populate_blackboard/1,
    snapshot_persists_through_lifecycle/1,
    checkpoint_redacts_llm_secrets/1,
    checkpoint_redacts_nested_llm_secrets/1,
    missing_credential_stops_the_run/1,
    invalid_credential_stops_the_run/1,
    failed_start_does_not_leak_the_credential/1,
    credential_survives_a_supervised_restart/1,
    raising_start_does_not_leak_the_credential/1,
    slow_start_keeps_a_live_runs_credential/1,
    nested_map_credential_is_redacted/1,
    live_credential_reaches_the_backend/1,
    stalled_registry_does_not_kill_the_run/1,
    composed_credential_absent_from_status/1,
    fork_keeps_caller_llm_spec/1,
    credential_absent_from_supervisor_and_status/1,
    tool_result_round_trip/1,
    tool_not_re_executed_on_replay/1,
    supervised_restart_restores_run/1,
    auto_continues_running_fanout_on_resume/1,
    lease_lost_fences_without_failing_snapshot/1
]).

all() ->
    [
        snapshot_round_trip,
        list_active_returns_running_runs,
        step_record_round_trip,
        interrupt_then_resume,
        initial_messages_populate_blackboard,
        snapshot_persists_through_lifecycle,
        checkpoint_redacts_llm_secrets,
        checkpoint_redacts_nested_llm_secrets,
        missing_credential_stops_the_run,
        invalid_credential_stops_the_run,
        failed_start_does_not_leak_the_credential,
        credential_survives_a_supervised_restart,
        raising_start_does_not_leak_the_credential,
        slow_start_keeps_a_live_runs_credential,
        nested_map_credential_is_redacted,
        live_credential_reaches_the_backend,
        stalled_registry_does_not_kill_the_run,
        composed_credential_absent_from_status,
        fork_keeps_caller_llm_spec,
        credential_absent_from_supervisor_and_status,
        tool_result_round_trip,
        tool_not_re_executed_on_replay,
        supervised_restart_restores_run,
        auto_continues_running_fanout_on_resume,
        lease_lost_fences_without_failing_snapshot
    ].

init_per_suite(Config) ->
    Backend = gakudan_checkpointer_ets:new(),
    application:set_env(gakudan, default_checkpointer, {gakudan_checkpointer_ets, Backend}),
    {ok, _} = application:ensure_all_started(gakudan),
    [{backend, Backend} | Config].

end_per_suite(_Config) ->
    application:stop(gakudan),
    ok.

init_per_testcase(_Name, Config) ->
    Backend = proplists:get_value(backend, Config),
    ok = gakudan_checkpointer_ets:reset(Backend),
    Config.

end_per_testcase(_Name, _Config) ->
    ok.

snapshot_round_trip(Config) ->
    Backend = proplists:get_value(backend, Config),
    {ok, Handle} = gakudan_checkpointer:init(gakudan_checkpointer_ets, Backend),
    RunId = ~"run-rt-1",
    Snapshot = base_snapshot(RunId, idle),
    ok = gakudan_checkpointer:save_snapshot(Handle, Snapshot),
    {ok, Loaded} = gakudan_checkpointer:load_snapshot(Handle, RunId),
    RunId = maps:get(run_id, Loaded),
    idle = maps:get(status, Loaded),
    ok = gakudan_checkpointer:delete_run(Handle, RunId),
    {error, not_found} = gakudan_checkpointer:load_snapshot(Handle, RunId).

list_active_returns_running_runs(Config) ->
    Backend = proplists:get_value(backend, Config),
    {ok, Handle} = gakudan_checkpointer:init(gakudan_checkpointer_ets, Backend),
    ok = gakudan_checkpointer:save_snapshot(Handle, base_snapshot(~"a-1", running)),
    ok = gakudan_checkpointer:save_snapshot(Handle, base_snapshot(~"a-2", awaiting_human)),
    ok = gakudan_checkpointer:save_snapshot(Handle, base_snapshot(~"a-3", completed)),
    {ok, Active} = gakudan_checkpointer:list_active(Handle),
    true = lists:member(~"a-1", Active),
    true = lists:member(~"a-2", Active),
    false = lists:member(~"a-3", Active).

step_record_round_trip(Config) ->
    Backend = proplists:get_value(backend, Config),
    {ok, Handle} = gakudan_checkpointer:init(gakudan_checkpointer_ets, Backend),
    Step = #{
        run_id => ~"run-step-1",
        step_id => ~"step-aaa",
        agent_id => agent_a,
        turn => 1,
        request => #{model => ~"m"},
        response => #{stop_reason => end_turn, usage => #{input_tokens => 5, output_tokens => 7}},
        usage => #{input_tokens => 5, output_tokens => 7},
        inserted_at => erlang:system_time(millisecond)
    },
    ok = gakudan_checkpointer:save_step(Handle, Step),
    {ok, Loaded} = gakudan_checkpointer:load_step(Handle, ~"run-step-1", ~"step-aaa"),
    ~"step-aaa" = maps:get(step_id, Loaded),
    agent_a = maps:get(agent_id, Loaded),
    1 = maps:get(turn, Loaded).

interrupt_then_resume(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([
        {text, ~"first"}, {text, ~"second"}, {text, ~"third"}, {text, ~"fourth"}
    ]),
    {ok, _Sup, RunId} = start_run(Script, 8),
    ok = gakudan:send(RunId, ~"begin"),
    {ok, _} = gakudan:await(RunId, 5000),
    ok = gakudan:interrupt(RunId, ~"hold"),
    {ok, awaiting_human} = gakudan:status(RunId),
    {ok, BB} = gakudan_run:blackboard(RunId),
    Entries = gakudan_blackboard:entries(BB),
    true = lists:any(
        fun
            (#{role := system, content := C}) ->
                binary:match(C, ~"interrupted: hold") =/= nomatch;
            (_) ->
                false
        end,
        Entries
    ),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

checkpoint_redacts_llm_secrets(Config) ->
    Backend = proplists:get_value(backend, Config),
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"ack"}]),
    {ok, _Sup, RunId} = gakudan:start_run(#{
        agents => [agent_a_mod],
        router => {gakudan_router_round_robin, #{}},
        llm =>
            {gakudan_llm_stub, #{
                script_owner => Script,
                api_key => ~"sk-ant-must-not-be-persisted",
                access_token => ~"ya29-must-not-be-persisted"
            }},
        max_turns => 1
    }),
    ok = gakudan:send(RunId, ~"go"),
    {ok, _} = gakudan:await(RunId, 5000),

    {ok, Handle} = gakudan_checkpointer:init(gakudan_checkpointer_ets, Backend),
    {ok, Snapshot} = gakudan_checkpointer:load_snapshot(Handle, RunId),
    {gakudan_llm_stub, Opts} = maps:get(llm, maps:get(config, Snapshot)),

    false = maps:is_key(api_key, Opts),
    false = maps:is_key(access_token, Opts),
    true = maps:is_key(script_owner, Opts),

    nomatch = binary:match(term_to_binary(Snapshot), ~"sk-ant-must-not-be-persisted"),
    nomatch = binary:match(term_to_binary(Snapshot), ~"ya29-must-not-be-persisted"),

    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

checkpoint_redacts_nested_llm_secrets(Config) ->
    Backend = proplists:get_value(backend, Config),
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"ack"}]),
    {ok, _Sup, RunId} = gakudan:start_run(#{
        agents => [agent_a_mod],
        router => {gakudan_router_round_robin, #{}},
        llm =>
            {gakudan_llm_retry, #{
                base_delay => 1,
                backend =>
                    {gakudan_llm_stub, #{
                        script_owner => Script,
                        api_key => ~"sk-ant-nested-must-not-persist"
                    }}
            }},
        max_turns => 1
    }),
    ok = gakudan:send(RunId, ~"go"),
    {ok, _} = gakudan:await(RunId, 5000),

    {ok, Handle} = gakudan_checkpointer:init(gakudan_checkpointer_ets, Backend),
    {ok, Snapshot} = gakudan_checkpointer:load_snapshot(Handle, RunId),
    {gakudan_llm_retry, RetryOpts} = maps:get(llm, maps:get(config, Snapshot)),
    {gakudan_llm_stub, Inner} = maps:get(backend, RetryOpts),

    false = maps:is_key(api_key, Inner),
    true = maps:is_key(script_owner, Inner),
    1 = maps:get(base_delay, RetryOpts),
    nomatch = binary:match(term_to_binary(Snapshot), ~"sk-ant-nested-must-not-persist"),

    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

credential_absent_from_supervisor_and_status(_Config) ->
    Key = ~"sk-ant-must-not-reach-a-log",
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"ack"}]),
    {ok, Sup, RunId} = gakudan:start_run(#{
        agents => [agent_a_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script, api_key => Key}},
        max_turns => 1
    }),
    {run_statem, StatemPid, _, _} = lists:keyfind(
        run_statem, 1, supervisor:which_children(Sup)
    ),

    %% sys:get_status is reachable by any process on the node, and the same
    %% rendering is what a supervisor crash report prints.
    Status = sys:get_status(StatemPid),
    nomatch = binary:match(iolist_to_binary(io_lib:format("~p", [Status])), Key),

    %% The child spec args are what `child_terminated` / `start_error` echo.
    ChildSpecs = supervisor:get_childspec(Sup, run_statem),
    nomatch = binary:match(iolist_to_binary(io_lib:format("~p", [ChildSpecs])), Key),

    %% ...and the run still authenticates, because the real spec is vaulted.
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

fork_keeps_caller_llm_spec(Config) ->
    Backend = proplists:get_value(backend, Config),
    {ok, Handle} = gakudan_checkpointer:init(gakudan_checkpointer_ets, Backend),
    SrcId = ~"fork-src-llm",
    ok = gakudan_checkpointer:save_snapshot(Handle, #{
        run_id => SrcId,
        status => idle,
        config => #{
            run_id => SrcId,
            agents => [agent_a_mod],
            router => {gakudan_router_round_robin, #{}},
            llm => {gakudan_llm_stub, #{}}
        },
        last_step => 0,
        blackboard => [#{seq => 1, role => user, content => ~"task", ts => 1}],
        kv => #{},
        router_state => undefined,
        statem_state => idle,
        turn => 1,
        updated_at => erlang:system_time(millisecond)
    }),
    ok = gakudan_checkpointer:save_step(Handle, #{
        run_id => SrcId,
        step_id => ~"fp",
        agent_id => agent_a,
        turn => 1,
        request => #{model => ~"m", messages => [#{role => user}]},
        response => #{content => []},
        usage => #{input_tokens => 1, output_tokens => 1},
        inserted_at => erlang:system_time(millisecond)
    }),

    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"go on"}]),
    {ok, _Sup, ForkId} = gakudan:start_run(#{
        agents => [agent_a_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script, api_key => ~"sk-caller-wins"}},
        max_turns => 1,
        fork_from => {SrcId, ~"fp"}
    }),

    %% The fork source's config carries no key; the caller's must survive.
    ok = gakudan:stop(ForkId),
    gen_server:stop(Script).

missing_credential_stops_the_run(Config) ->
    Backend = proplists:get_value(backend, Config),
    {ok, _Sup, RunId} = gakudan:start_run(#{
        agents => [agent_a_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {no_credential_llm_mod, #{}},
        max_turns => 4
    }),
    ok = gakudan:send(RunId, ~"go"),
    ok = wait_until_gone(RunId, 5000),

    {ok, Handle} = gakudan_checkpointer:init(gakudan_checkpointer_ets, Backend),
    {ok, Snap} = gakudan_checkpointer:load_snapshot(Handle, RunId),
    failed = maps:get(status, Snap),

    %% and therefore the resumer will not pick it up again on the next boot
    {ok, Active} = gakudan_checkpointer:list_active(Handle),
    false = lists:any(fun(S) -> maps:get(run_id, S) =:= RunId end, Active).

composed_credential_absent_from_status(_Config) ->
    Key = ~"sk-ant-composed-must-not-log",
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"ack"}]),
    {ok, Sup, RunId} = gakudan:start_run(#{
        agents => [agent_a_mod],
        router => {gakudan_router_round_robin, #{}},
        llm =>
            {gakudan_llm_retry, #{
                base_delay => 1,
                backend => {gakudan_llm_stub, #{script_owner => Script, api_key => Key}}
            }},
        max_turns => 1
    }),
    {run_statem, Pid, _, _} = lists:keyfind(run_statem, 1, supervisor:which_children(Sup)),

    %% format_status/1 must redact a COMPOSED backend, not just a flat one -
    %% this is the surface a supervisor crash report and sys:get_status share.
    Status = sys:get_status(Pid),
    nomatch = binary:match(iolist_to_binary(io_lib:format("~p", [Status])), Key),

    %% Documented residual: sys:get_state/1 bypasses format_status/1, so a
    %% caller who can run code on the node can read the live credential. That
    %% is accepted - see ADR 0003 - because holding it process-local is what
    %% makes collision and lifetime bugs impossible.

    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

failed_start_does_not_leak_the_credential(_Config) ->
    0 = gakudan_registry:stash_count(),
    RunId = ~"leak-probe-run",
    Res = gakudan:start_run(#{
        run_id => RunId,
        agents => [agent_a_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{api_key => ~"sk-must-not-survive"}},
        checkpointer => {no_such_checkpointer_mod, #{}}
    }),
    {error, _} = Res,
    ?assertEqual(0, gakudan_registry:stash_count()).

credential_survives_a_supervised_restart(_Config) ->
    Key = ~"sk-must-survive-a-restart",
    Self = self(),
    {ok, Sup, RunId} = gakudan:start_run(#{
        agents => [agent_a_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {opts_probe_llm_mod, #{api_key => Key, probe_owner => Self}},
        max_turns => 8
    }),

    %% run_sup is one_for_all: killing a sibling restarts the statem, which
    %% must come back still able to authenticate.
    {stream, StreamPid, _, _} = lists:keyfind(stream, 1, supervisor:which_children(Sup)),
    MRef = erlang:monitor(process, StreamPid),
    exit(StreamPid, kill),
    receive
        {'DOWN', MRef, process, _, _} -> ok
    after 5000 -> ct:fail(stream_did_not_die)
    end,
    timer:sleep(300),

    ok = gakudan:send(RunId, ~"go"),
    receive
        {seen_opts, Opts} -> ?assertEqual(Key, maps:get(api_key, Opts, missing))
    after 5000 -> ct:fail(backend_never_called_after_restart)
    end,
    _ = gakudan:stop(RunId).

stalled_registry_does_not_kill_the_run(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"a"}]),
    {ok, Sup, RunId} = gakudan:start_run(#{
        agents => [agent_a_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script, api_key => ~"sk-x"}},
        max_turns => 1
    }),
    {run_statem, Statem, _, _} = lists:keyfind(run_statem, 1, supervisor:which_children(Sup)),
    ok = sys:suspend(gakudan_registry),
    _ = spawn(fun() -> gakudan:send(RunId, ~"go") end),
    timer:sleep(6500),
    Alive = is_process_alive(Statem),
    ok = sys:resume(gakudan_registry),
    ?assert(Alive),
    _ = gakudan:stop(RunId),
    gen_server:stop(Script).

live_credential_reaches_the_backend(_Config) ->
    Key = ~"sk-live-key-must-reach-backend",
    Self = self(),
    {ok, _Sup, RunId} = gakudan:start_run(#{
        agents => [agent_a_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {opts_probe_llm_mod, #{api_key => Key, probe_owner => Self}},
        max_turns => 1
    }),
    ok = gakudan:send(RunId, ~"go"),
    receive
        {seen_opts, Opts} -> ?assertEqual(Key, maps:get(api_key, Opts, missing))
    after 5000 -> ct:fail(backend_never_called)
    end,
    _ = gakudan:stop(RunId).

raising_start_does_not_leak_the_credential(_Config) ->
    0 = gakudan_registry:stash_count(),
    RunId = ~"raise-probe-run",
    _ =
        try
            gakudan:start_run(#{
                run_id => RunId,
                agents => [agent_a_mod],
                router => {gakudan_router_round_robin, #{}},
                llm => {gakudan_llm_stub, #{api_key => ~"sk-must-not-survive-a-raise"}},
                checkpointer => not_a_valid_spec
            })
        catch
            _:_ -> raised
        end,
    ?assertEqual(0, gakudan_registry:stash_count()).

nested_map_credential_is_redacted(Config) ->
    Backend = proplists:get_value(backend, Config),
    Key = ~"sk-inside-a-plain-map",
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"ack"}]),
    {ok, _Sup, RunId} = gakudan:start_run(#{
        agents => [agent_a_mod],
        router => {gakudan_router_round_robin, #{}},
        %% not a nested SPEC - a plain map value, the shape a consumer's own
        %% composed backend uses and the shape the docstring promises to cover
        llm => {gakudan_llm_stub, #{script_owner => Script, auth => #{api_key => Key}}},
        max_turns => 1
    }),
    ok = gakudan:send(RunId, ~"go"),
    {ok, _} = gakudan:await(RunId, 5000),

    {ok, Handle} = gakudan_checkpointer:init(gakudan_checkpointer_ets, Backend),
    {ok, Snapshot} = gakudan_checkpointer:load_snapshot(Handle, RunId),
    ?assertEqual(nomatch, binary:match(term_to_binary(Snapshot), Key)),

    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

slow_start_keeps_a_live_runs_credential(_Config) ->
    0 = gakudan_registry:stash_count(),
    Key = ~"sk-slow-start-must-keep",
    Self = self(),
    RunId = ~"slow-start-run",
    %% wait_ready times out while the run is alive: the cleanup path must not
    %% strip a credential from a run that actually started.
    _ =
        try
            gakudan:start_run(#{
                run_id => RunId,
                agents => [agent_a_mod],
                router => {gakudan_router_round_robin, #{}},
                llm => {opts_probe_llm_mod, #{api_key => Key, probe_owner => Self}},
                checkpointer => {slow_init_checkpointer, #{}},
                max_turns => 2
            })
        catch
            _:_ -> raised
        end,
    timer:sleep(500),

    %% The run is alive, so its stash must still be there - a restart re-reads
    %% it at init, and stripping it would leave the restarted statem with no
    %% credential and the run torn down as no_credentials.
    ?assertEqual(1, gakudan_registry:stash_count()),

    ok = gakudan:send(RunId, ~"go"),
    receive
        {seen_opts, Opts} -> ?assertEqual(Key, maps:get(api_key, Opts, missing))
    after 10000 -> ct:fail(backend_never_called)
    end,
    _ = gakudan:stop(RunId).

invalid_credential_stops_the_run(Config) ->
    Backend = proplists:get_value(backend, Config),
    {ok, _Sup, RunId} = gakudan:start_run(#{
        agents => [agent_a_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {rejected_credential_llm_mod, #{}},
        max_turns => 4
    }),
    ok = gakudan:send(RunId, ~"go"),
    ok = wait_until_gone(RunId, 5000),
    {ok, Handle} = gakudan_checkpointer:init(gakudan_checkpointer_ets, Backend),
    {ok, Snap} = gakudan_checkpointer:load_snapshot(Handle, RunId),
    failed = maps:get(status, Snap).

initial_messages_populate_blackboard(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"ack"}]),
    {ok, _Sup, RunId} = gakudan:start_run(#{
        agents => [agent_a_mod, agent_b_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => 2,
        initial_messages => [
            #{role => system, content => ~"context blob A"},
            #{role => system, content => ~"context blob B"}
        ]
    }),
    {ok, BB} = gakudan_run:blackboard(RunId),
    Entries = gakudan_blackboard:entries(BB),
    SystemTexts = [maps:get(content, E) || E <- Entries, maps:get(role, E) =:= system],
    true = lists:member(~"context blob A", SystemTexts),
    true = lists:member(~"context blob B", SystemTexts),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

snapshot_persists_through_lifecycle(Config) ->
    Backend = proplists:get_value(backend, Config),
    {ok, Script} = gakudan_llm_stub_script:start_link([
        {text, ~"first"}, {text, ~"second"}, {text, ~"third"}, {text, ~"fourth"}
    ]),
    {ok, _Sup, RunId} = start_run(Script, 8),
    ok = gakudan:send(RunId, ~"begin"),
    {ok, _} = gakudan:await(RunId, 5000),
    ok = gakudan:interrupt(RunId, ~"hold"),
    {ok, awaiting_human} = gakudan:status(RunId),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script),
    {ok, Handle} = gakudan_checkpointer:init(gakudan_checkpointer_ets, Backend),
    {ok, Snap} = gakudan_checkpointer:load_snapshot(Handle, RunId),
    awaiting_human = maps:get(status, Snap),
    Entries = maps:get(blackboard, Snap),
    true = length(Entries) >= 2.

tool_result_round_trip(Config) ->
    Backend = proplists:get_value(backend, Config),
    {ok, Handle} = gakudan_checkpointer:init(gakudan_checkpointer_ets, Backend),
    Rec = #{
        run_id => ~"run-tr-1",
        tool_step_id => ~"ts-aaa",
        agent_id => agent_a,
        turn => 1,
        tool_name => ~"echo_tool",
        output => ~"hello",
        inserted_at => erlang:system_time(millisecond)
    },
    ok = gakudan_checkpointer:save_tool_result(Handle, Rec),
    {ok, Loaded} = gakudan_checkpointer:load_tool_result(Handle, ~"run-tr-1", ~"ts-aaa"),
    ~"ts-aaa" = maps:get(tool_step_id, Loaded),
    ~"hello" = maps:get(output, Loaded),
    {error, not_found} = gakudan_checkpointer:load_tool_result(Handle, ~"run-tr-1", ~"missing").

tool_not_re_executed_on_replay(Config) ->
    Backend = proplists:get_value(backend, Config),
    {ok, Handle} = gakudan_checkpointer:init(gakudan_checkpointer_ets, Backend),
    ok = counter_tool_mod:reset(),
    {ok, Script} = gakudan_llm_stub_script:start_link([
        {tool_use, ~"counter_tool", #{}},
        {text, ~"done"}
    ]),
    LOpts = #{script_owner => Script},
    RunId = ~"run-tool-idem",

    {ok, BB1} = gakudan_blackboard:start_link(RunId),
    ok = gakudan_turn:run(
        RunId,
        counter_agent,
        agent_with_counter_mod,
        1,
        Handle,
        gakudan_llm_stub,
        LOpts,
        BB1,
        undefined,
        []
    ),
    1 = counter_tool_mod:count(),

    %% Replay the same turn. The LLM step and the tool result are both
    %% cached, so the tool must not run a second time.
    {ok, BB2} = gakudan_blackboard:start_link(RunId),
    ok = gakudan_turn:run(
        RunId,
        counter_agent,
        agent_with_counter_mod,
        1,
        Handle,
        gakudan_llm_stub,
        LOpts,
        BB2,
        undefined,
        []
    ),
    1 = counter_tool_mod:count(),

    gen_server:stop(Script).

supervised_restart_restores_run(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([
        {text, ~"alpha"}, {text, ~"beta"}, {text, ~"gamma"}, {text, ~"delta"}
    ]),
    {ok, _Sup, RunId} = start_run(Script, 8),
    ok = gakudan:send(RunId, ~"go"),
    {ok, _} = gakudan:await(RunId, 5000),
    {ok, BB0} = gakudan_run:blackboard(RunId),
    Before = length(gakudan_blackboard:entries(BB0)),
    true = Before > 0,

    %% Kill the run statem; one_for_all restarts the children and the new
    %% statem must rehydrate from the snapshot and restore the transcript.
    {ok, #{run_statem := StatemPid}} = gakudan_registry:lookup(RunId),
    MRef = erlang:monitor(process, StatemPid),
    exit(StatemPid, kill),
    receive
        {'DOWN', MRef, process, StatemPid, _} -> ok
    after 2000 -> ct:fail(statem_not_killed)
    end,

    ok = wait_until_idle(RunId, 5000),
    {ok, BB1} = gakudan_run:blackboard(RunId),
    After = length(gakudan_blackboard:entries(BB1)),
    true = After >= Before,

    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

auto_continues_running_fanout_on_resume(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"resumed-output"}]),
    RunId = ~"run-autocont",
    Config = #{
        run_id => RunId,
        agents => [agent_a_mod, agent_b_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => 4
    },
    %% A snapshot captured mid-fanout: agent_a was dispatched as turn 1 but
    %% never finished, and the router state is already past that decision.
    {ok, R0} = gakudan_router_round_robin:init(#{}, [agent_a, agent_b]),
    {next, agent_a, R1} = gakudan_router_round_robin:next(R0, []),
    Snapshot = #{
        run_id => RunId,
        status => running,
        config => Config,
        last_step => 0,
        blackboard => [#{seq => 1, role => user, content => ~"go", ts => 0}],
        kv => #{},
        router_state => R1,
        statem_state => running,
        turn => 0,
        fanout => #{base => 0, agents => [agent_a]},
        updated_at => erlang:system_time(millisecond)
    },
    {ok, _Sup, RunId} = gakudan_runs_sup:resume_run(Config, Snapshot),
    {ok, Entries} = gakudan:await(RunId, 5000),
    %% The in-flight fanout re-ran: agent_a produced its output after resume.
    AgentAOutputs = [
        maps:get(content, E)
     || E <- Entries, maps:get(role, E) =:= {agent, agent_a}
    ],
    true = lists:member(~"resumed-output", AgentAOutputs),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

%% The fence guarantee of ADR 0023: when a snapshot write is refused with
%% `lease_lost`, the run stops locally and must NOT write a failed/completed
%% snapshot on teardown (the new owner holds the run).
lease_lost_fences_without_failing_snapshot(_Config) ->
    HandlerId = {?MODULE, lease_lost},
    Self = self(),
    telemetry:attach(
        HandlerId,
        [gakudan, lease, lost],
        fun(_E, _M, Meta, _) -> Self ! {lease_lost_event, Meta} end,
        undefined
    ),
    try
        {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"x"}]),
        {ok, _Sup, RunId} = gakudan:start_run(#{
            agents => [agent_a_mod],
            router => {gakudan_router_round_robin, #{}},
            llm => {gakudan_llm_stub, #{script_owner => Script}},
            checkpointer => {gakudan_checkpointer_fence_stub, #{report => Self}},
            max_turns => 4
        }),
        %% The first save (entering idle) is refused, fencing the run.
        receive
            {lease_lost_event, Meta} -> RunId = maps:get(run_id, Meta)
        after 5000 -> ct:fail(no_lease_lost_telemetry)
        end,
        ok = wait_until_gone(RunId, 5000),
        %% Only the initial idle write was attempted; teardown wrote nothing.
        [idle] = drain_fence_saves([])
    after
        telemetry:detach(HandlerId)
    end.

drain_fence_saves(Acc) ->
    receive
        {fence_save, Status} -> drain_fence_saves([Status | Acc])
    after 200 -> lists:reverse(Acc)
    end.

wait_until_gone(RunId, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_until_gone_loop(RunId, Deadline).

wait_until_gone_loop(RunId, Deadline) ->
    case gakudan_registry:lookup(RunId) of
        {error, not_found} ->
            ok;
        {ok, _} ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    ct:fail(run_not_torn_down);
                false ->
                    timer:sleep(50),
                    wait_until_gone_loop(RunId, Deadline)
            end
    end.

start_run(Script, MaxTurns) ->
    gakudan:start_run(#{
        agents => [agent_a_mod, agent_b_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => MaxTurns
    }).

base_snapshot(RunId, Status) ->
    #{
        run_id => RunId,
        status => Status,
        config => #{
            run_id => RunId,
            agents => [agent_a_mod],
            router => {gakudan_router_round_robin, #{}},
            llm => {gakudan_llm_stub, #{}}
        },
        last_step => 0,
        blackboard => [],
        kv => #{},
        router_state => undefined,
        statem_state => Status,
        turn => 0,
        updated_at => erlang:system_time(millisecond)
    }.

wait_until_idle(RunId, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_until_idle_loop(RunId, Deadline).

wait_until_idle_loop(RunId, Deadline) ->
    Status =
        try
            gakudan:status(RunId)
        catch
            _:_ -> retry
        end,
    case Status of
        {ok, idle} ->
            ok;
        _ ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    ct:fail(not_idle_after_restart);
                false ->
                    timer:sleep(50),
                    wait_until_idle_loop(RunId, Deadline)
            end
    end.
