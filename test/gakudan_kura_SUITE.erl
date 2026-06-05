-module(gakudan_kura_SUITE).
-moduledoc """
Durability suite: drives the kura-backed checkpointer, the hash-chained audit
sink, and the runs resumer against a real Postgres (the unit suites use ETS
stubs, leaving these production paths uncovered).

Needs a database: `docker compose up -d` (Postgres on localhost:5555,
db `gakudan_test`). When no database is reachable the whole suite skips, so
it is safe to run without Docker. Connection is overridable via
`GAKUDAN_TEST_DB_{HOST,PORT,USER,PASSWORD,DB}`.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    ckpt_snapshot_round_trip/1,
    ckpt_snapshot_update/1,
    ckpt_list_active/1,
    ckpt_delete_run/1,
    ckpt_step_round_trip/1,
    ckpt_tool_result_round_trip/1,
    audit_record_and_list/1,
    audit_verify_intact_chain/1,
    audit_tamper_breaks_chain/1,
    resumer_respawns_active_run/1,
    lease_claim_and_contention/1,
    lease_expiry_reclaim/1,
    lease_fenced_write/1,
    lease_renew_holds/1,
    lease_release_frees/1,
    lease_owned_insert/1
]).

-define(REPO, gakudan_test_repo).

all() ->
    [
        ckpt_snapshot_round_trip,
        ckpt_snapshot_update,
        ckpt_list_active,
        ckpt_delete_run,
        ckpt_step_round_trip,
        ckpt_tool_result_round_trip,
        audit_record_and_list,
        audit_verify_intact_chain,
        audit_tamper_breaks_chain,
        resumer_respawns_active_run,
        lease_claim_and_contention,
        lease_expiry_reclaim,
        lease_fenced_write,
        lease_renew_holds,
        lease_release_frees,
        lease_owned_insert
    ].

%%----------------------------------------------------------------------
%% Suite setup: real Postgres or skip
%%----------------------------------------------------------------------

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(kura),
    {ok, _} = application:ensure_all_started(kura_postgres),
    ok = gakudan_test_repo:start(),
    case wait_for_db(15) of
        true ->
            reset_schema(),
            Config;
        false ->
            {skip, postgres_unreachable}
    end.

end_per_suite(_Config) ->
    _ = application:stop(gakudan),
    ok.

init_per_testcase(_Case, Config) ->
    truncate_all(),
    Config.

end_per_testcase(_Case, _Config) ->
    _ = application:stop(gakudan),
    ok.

%%----------------------------------------------------------------------
%% Checkpointer (gakudan_checkpointer_kura)
%%----------------------------------------------------------------------

ckpt_snapshot_round_trip(_Config) ->
    H = checkpointer(),
    RunId = ~"run-rt",
    ok = gakudan_checkpointer:save_snapshot(H, snapshot(RunId, idle)),
    {ok, Loaded} = gakudan_checkpointer:load_snapshot(H, RunId),
    ?assertEqual(RunId, maps:get(run_id, Loaded)),
    ?assertEqual(idle, maps:get(status, Loaded)),
    ?assertEqual([agent_a_mod], maps:get(agents, maps:get(config, Loaded))),
    ?assertEqual({error, not_found}, gakudan_checkpointer:load_snapshot(H, ~"nope")).

ckpt_snapshot_update(_Config) ->
    H = checkpointer(),
    RunId = ~"run-upd",
    ok = gakudan_checkpointer:save_snapshot(H, snapshot(RunId, running)),
    ok = gakudan_checkpointer:save_snapshot(H, (snapshot(RunId, idle))#{turn => 7}),
    {ok, Loaded} = gakudan_checkpointer:load_snapshot(H, RunId),
    ?assertEqual(idle, maps:get(status, Loaded)),
    ?assertEqual(7, maps:get(turn, Loaded)).

ckpt_list_active(_Config) ->
    H = checkpointer(),
    ok = gakudan_checkpointer:save_snapshot(H, snapshot(~"a-running", running)),
    ok = gakudan_checkpointer:save_snapshot(H, snapshot(~"a-idle", idle)),
    ok = gakudan_checkpointer:save_snapshot(H, snapshot(~"a-awaiting", awaiting_human)),
    ok = gakudan_checkpointer:save_snapshot(H, snapshot(~"a-done", completed)),
    {ok, Active} = gakudan_checkpointer:list_active(H),
    ?assertEqual(
        [~"a-awaiting", ~"a-idle", ~"a-running"],
        lists:sort(Active)
    ).

ckpt_delete_run(_Config) ->
    H = checkpointer(),
    RunId = ~"run-del",
    ok = gakudan_checkpointer:save_snapshot(H, snapshot(RunId, running)),
    {ok, _} = gakudan_checkpointer:load_snapshot(H, RunId),
    ok = gakudan_checkpointer:delete_run(H, RunId),
    ?assertEqual({error, not_found}, gakudan_checkpointer:load_snapshot(H, RunId)).

ckpt_step_round_trip(_Config) ->
    H = checkpointer(),
    RunId = ~"run-step",
    Step = #{
        run_id => RunId,
        step_id => ~"step-1",
        agent_id => agent_a,
        turn => 2,
        request => #{model => ~"m"},
        response => #{stop_reason => end_turn, usage => #{input_tokens => 3, output_tokens => 4}},
        usage => #{input_tokens => 3, output_tokens => 4},
        inserted_at => erlang:system_time(millisecond)
    },
    ok = gakudan_checkpointer:save_step(H, Step),
    {ok, Loaded} = gakudan_checkpointer:load_step(H, RunId, ~"step-1"),
    ?assertEqual(~"step-1", maps:get(step_id, Loaded)),
    ?assertEqual(agent_a, maps:get(agent_id, Loaded)),
    ?assertEqual(2, maps:get(turn, Loaded)).

ckpt_tool_result_round_trip(_Config) ->
    H = checkpointer(),
    RunId = ~"run-tool",
    Rec = #{
        run_id => RunId,
        tool_step_id => ~"tool-1",
        agent_id => agent_a,
        turn => 1,
        tool_name => ~"echo",
        result => #{ok => true},
        inserted_at => erlang:system_time(millisecond)
    },
    ok = gakudan_checkpointer:save_tool_result(H, Rec),
    {ok, Loaded} = gakudan_checkpointer:load_tool_result(H, RunId, ~"tool-1"),
    ?assertEqual(~"tool-1", maps:get(tool_step_id, Loaded)),
    ?assertEqual(~"echo", maps:get(tool_name, Loaded)).

%%----------------------------------------------------------------------
%% Audit (gakudan_audit_kura) - hash-chained, tamper-evident
%%----------------------------------------------------------------------

audit_record_and_list(_Config) ->
    {ok, S} = gakudan_audit_kura:init(#{repo => ?REPO}),
    RunId = ~"run-audit-list",
    ok = gakudan_audit_kura:record(S, audit_event(run_started, RunId)),
    ok = gakudan_audit_kura:record(S, audit_event(guardrail_allow, RunId)),
    ok = gakudan_audit_kura:record(S, audit_event(run_stopped, RunId)),
    {ok, Events} = gakudan_audit_kura:list(S, RunId),
    ?assertEqual(3, length(Events)),
    Types = lists:sort([maps:get(type, E) || E <- Events]),
    ?assertEqual([guardrail_allow, run_started, run_stopped], Types),
    ?assert(lists:all(fun(E) -> maps:get(run_id, E) =:= RunId end, Events)).

audit_verify_intact_chain(_Config) ->
    {ok, S} = gakudan_audit_kura:init(#{repo => ?REPO}),
    RunId = ~"run-audit-ok",
    [ok = gakudan_audit_kura:record(S, audit_event(T, RunId)) || T <- chain_types()],
    ?assertEqual(ok, gakudan_audit_kura:verify(S, RunId)).

audit_tamper_breaks_chain(_Config) ->
    {ok, S} = gakudan_audit_kura:init(#{repo => ?REPO}),
    RunId = ~"run-audit-tamper",
    [ok = gakudan_audit_kura:record(S, audit_event(T, RunId)) || T <- chain_types()],
    ?assertEqual(ok, gakudan_audit_kura:verify(S, RunId)),
    %% Delete a middle row out from under the chain: the next row's prev-link
    %% no longer matches, so the chain must report tampering.
    #{command := delete} = kura_db:query(
        ?REPO,
        ~"DELETE FROM gakudan_audit WHERE run_id = $1 AND type = $2",
        [RunId, ~"guardrail_allow"]
    ),
    ?assertMatch({tampered, [_ | _]}, gakudan_audit_kura:verify(S, RunId)).

%%----------------------------------------------------------------------
%% Resumer (gakudan_runs_resumer) reading active runs from kura
%%----------------------------------------------------------------------

resumer_respawns_active_run(_Config) ->
    RunId = ~"run-resume",
    %% Seed a running snapshot into Postgres, then boot gakudan: the resumer
    %% must read it back from kura (list_active -> load_snapshot) and respawn
    %% the run's supervision tree.
    H = checkpointer(),
    ok = gakudan_checkpointer:save_snapshot(H, snapshot(RunId, running)),
    application:set_env(
        gakudan, default_checkpointer, {gakudan_checkpointer_kura, #{repo => ?REPO}}
    ),
    Self = self(),
    Ref = make_ref(),
    telemetry:attach_many(
        {?MODULE, Ref},
        [[gakudan, resume, succeeded], [gakudan, resume, failed]],
        fun(Event, _M, Meta, _C) -> Self ! {resume, lists:last(Event), Meta} end,
        undefined
    ),
    try
        {ok, _} = application:ensure_all_started(gakudan),
        receive
            {resume, succeeded, #{run_id := RunId}} ->
                ?assertMatch({ok, _}, gakudan_registry:lookup(RunId));
            {resume, failed, #{run_id := RunId, reason := Reason}} ->
                ct:fail({resume_failed, Reason})
        after 5000 ->
            ct:fail("resumer did not act on the active run from kura")
        end
    after
        telemetry:detach({?MODULE, Ref})
    end.

%%----------------------------------------------------------------------
%% Run leasing (ADR 0023). Lease expiry is second-resolution (utc_datetime),
%% so expiry tests claim with a 1ms TTL and sleep past a second boundary.
%%----------------------------------------------------------------------

lease_claim_and_contention(_Config) ->
    H = checkpointer(),
    ok = gakudan_checkpointer:save_snapshot(H, snapshot(~"L1", idle)),
    {ok, Claimed} = gakudan_checkpointer:claim_runs(H, ~"node-a", #{
        lease_ttl_ms => 60000, limit => 10
    }),
    ?assertEqual([~"L1"], [maps:get(run_id, S) || S <- Claimed]),
    %% A freshly-leased run cannot be stolen by another owner.
    ?assertEqual(
        {ok, []},
        gakudan_checkpointer:claim_runs(H, ~"node-b", #{lease_ttl_ms => 60000, limit => 10})
    ).

lease_expiry_reclaim(_Config) ->
    H = checkpointer(),
    ok = gakudan_checkpointer:save_snapshot(H, snapshot(~"L2", running)),
    {ok, [_]} = gakudan_checkpointer:claim_runs(H, ~"node-a", #{lease_ttl_ms => 1, limit => 10}),
    timer:sleep(2200),
    {ok, Reclaimed} = gakudan_checkpointer:claim_runs(H, ~"node-b", #{
        lease_ttl_ms => 60000, limit => 10
    }),
    ?assertEqual([~"L2"], [maps:get(run_id, S) || S <- Reclaimed]).

lease_fenced_write(_Config) ->
    H = checkpointer(),
    RunId = ~"L3",
    ok = gakudan_checkpointer:save_snapshot(H, owned_snapshot(RunId, running, ~"node-a", 1)),
    timer:sleep(2200),
    {ok, [_]} = gakudan_checkpointer:claim_runs(H, ~"node-b", #{lease_ttl_ms => 60000, limit => 10}),
    %% The old owner's write is refused; the new owner's succeeds.
    ?assertEqual(
        {error, lease_lost},
        gakudan_checkpointer:save_snapshot(H, owned_snapshot(RunId, idle, ~"node-a", 60000))
    ),
    ?assertEqual(
        ok,
        gakudan_checkpointer:save_snapshot(H, owned_snapshot(RunId, idle, ~"node-b", 60000))
    ).

lease_renew_holds(_Config) ->
    H = checkpointer(),
    RunId = ~"L4",
    ok = gakudan_checkpointer:save_snapshot(H, owned_snapshot(RunId, running, ~"node-a", 1)),
    timer:sleep(1100),
    %% A renews before B can steal.
    ?assertEqual({ok, [RunId]}, gakudan_checkpointer:renew_leases(H, ~"node-a", [RunId], 60000)),
    ?assertEqual(
        {ok, []},
        gakudan_checkpointer:claim_runs(H, ~"node-b", #{lease_ttl_ms => 60000, limit => 10})
    ),
    %% Renewing a run owned by someone else holds nothing.
    ?assertEqual({ok, []}, gakudan_checkpointer:renew_leases(H, ~"node-b", [RunId], 60000)).

lease_release_frees(_Config) ->
    H = checkpointer(),
    RunId = ~"L5",
    ok = gakudan_checkpointer:save_snapshot(H, owned_snapshot(RunId, running, ~"node-a", 60000)),
    ?assertEqual(
        {ok, []},
        gakudan_checkpointer:claim_runs(H, ~"node-b", #{lease_ttl_ms => 60000, limit => 10})
    ),
    ok = gakudan_checkpointer:release_run(H, ~"node-a", RunId),
    {ok, Claimed} = gakudan_checkpointer:claim_runs(H, ~"node-b", #{
        lease_ttl_ms => 60000, limit => 10
    }),
    ?assertEqual([RunId], [maps:get(run_id, S) || S <- Claimed]).

lease_owned_insert(_Config) ->
    H = checkpointer(),
    RunId = ~"L6",
    %% A run started under leasing: its first save is an owner-tagged insert
    %% (no prior row), which must land with the owner set.
    ok = gakudan_checkpointer:save_snapshot(H, owned_snapshot(RunId, running, ~"node-a", 60000)),
    {ok, Loaded} = gakudan_checkpointer:load_snapshot(H, RunId),
    ?assertEqual(running, maps:get(status, Loaded)),
    ?assertEqual(
        {ok, []},
        gakudan_checkpointer:claim_runs(H, ~"node-b", #{lease_ttl_ms => 60000, limit => 10})
    ).

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

checkpointer() ->
    {ok, H} = gakudan_checkpointer:init(gakudan_checkpointer_kura, #{repo => ?REPO}),
    H.

snapshot(RunId, Status) ->
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

owned_snapshot(RunId, Status, Owner, TtlMs) ->
    (snapshot(RunId, Status))#{owner => Owner, lease_ttl_ms => TtlMs}.

audit_event(Type, RunId) ->
    #{
        type => Type,
        run_id => RunId,
        timestamp => erlang:system_time(millisecond),
        actor => #{id => ~"actor-1", tenant => ~"tenant-1"},
        agent_id => agent_a,
        turn => 1
    }.

chain_types() ->
    [run_started, guardrail_allow, guardrail_block, run_stopped].

%%----------------------------------------------------------------------
%% Schema management (apply gakudan's migrations to the test DB)
%%----------------------------------------------------------------------

%% Wait for the database to accept queries (it may still be starting in CI),
%% so a slow container never turns into a false skip.
wait_for_db(0) ->
    db_reachable();
wait_for_db(N) ->
    case db_reachable() of
        true ->
            true;
        false ->
            timer:sleep(1000),
            wait_for_db(N - 1)
    end.

db_reachable() ->
    try kura_db:query(?REPO, ~"SELECT 1", []) of
        #{} -> true;
        _ -> false
    catch
        _:_ -> false
    end.

reset_schema() ->
    _ = kura_db:query(
        ?REPO,
        ~"DROP TABLE IF EXISTS gakudan_audit, gakudan_steps, gakudan_tool_results, gakudan_runs, schema_migrations CASCADE",
        []
    ),
    apply_migrations().

truncate_all() ->
    _ = kura_db:query(
        ?REPO,
        ~"TRUNCATE gakudan_audit, gakudan_steps, gakudan_tool_results, gakudan_runs",
        []
    ),
    ok.

apply_migrations() ->
    lists:foreach(
        fun({_Version, Module}) ->
            lists:foreach(
                fun(Op) ->
                    SQL = kura_migrator:compile_operation(?REPO, Op),
                    #{} = kura_db:query(?REPO, SQL, [])
                end,
                Module:up()
            )
        end,
        migration_modules()
    ).

migration_modules() ->
    _ = application:load(gakudan),
    {ok, Modules} = application:get_key(gakudan, modules),
    lists:sort(lists:filtermap(fun migration_version/1, Modules)).

migration_version(Module) ->
    case re:run(atom_to_list(Module), "^m([0-9]{14})_", [{capture, [1], list}]) of
        {match, [Version]} -> {true, {list_to_integer(Version), Module}};
        nomatch -> false
    end.
