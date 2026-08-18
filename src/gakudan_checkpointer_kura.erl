-module(gakudan_checkpointer_kura).
-moduledoc """
Default `gakudan_checkpointer` impl backed by `kura`.

Works against any kura backend (`kura_postgres`, `kura_sqlite`, future
`kura_mysql`). The schema is held in two tables, `gakudan_runs` and
`gakudan_steps`. Snapshot blobs are stored as `term_to_binary`.

Configuration:

```erlang
{checkpointer, {gakudan_checkpointer_kura, #{repo => my_repo}}}
```

`my_repo` must be a module implementing `kura_repo`, configured under
the `kura` application env in the host application's `sys.config`.
""".

-behaviour(gakudan_checkpointer).

-include_lib("kura/include/kura.hrl").

-export([
    init/1,
    save_snapshot/2,
    load_snapshot/2,
    list_active/1,
    delete_run/2,
    save_step/2,
    load_step/3,
    save_tool_result/2,
    load_tool_result/3,
    claim_runs/3,
    renew_leases/4,
    release_run/3
]).

-export_type([state/0]).

-type state() :: #{repo := module()}.

-spec init(map()) -> {ok, state()} | {error, term()}.
init(#{repo := Repo}) when is_atom(Repo) ->
    {ok, #{repo => Repo}};
init(_) ->
    {error, {bad_config, missing_repo}}.

-spec save_snapshot(state(), gakudan_checkpointer:run_snapshot()) ->
    ok | {error, lease_lost | term()}.
save_snapshot(#{repo := Repo}, Snapshot) ->
    case maps:get(owner, Snapshot, undefined) of
        undefined -> save_snapshot_plain(Repo, Snapshot);
        Owner -> save_snapshot_owned(Repo, Snapshot, Owner)
    end.

save_snapshot_plain(Repo, Snapshot) ->
    #{
        run_id := RunId,
        status := Status,
        last_step := LastStep,
        updated_at := UpdatedAt
    } = Snapshot,
    Now = system_time_datetime(UpdatedAt),
    Changes = #{
        run_id => RunId,
        status => status_to_binary(Status),
        last_step => LastStep,
        data => term_to_binary(Snapshot),
        updated_at => Now
    },
    case kura_repo_worker:get(Repo, gakudan_run_schema, RunId) of
        {ok, Existing} ->
            CS = kura_changeset:cast(
                gakudan_run_schema,
                Existing,
                Changes,
                [status, last_step, data, updated_at]
            ),
            normalise(kura_repo_worker:update(Repo, CS));
        {error, not_found} ->
            FullChanges = Changes#{inserted_at => Now},
            CS = kura_changeset:cast(
                gakudan_run_schema,
                #{},
                FullChanges,
                [run_id, status, last_step, data, updated_at, inserted_at]
            ),
            normalise(kura_repo_worker:insert(Repo, CS));
        {error, _} = Err ->
            Err
    end.

%% Lease-aware write. Locks the run row FOR UPDATE; an existing row owned by
%% another node fails the ownership check and the write is refused with
%% `lease_lost`. A successful write also renews the lease. The expiry is
%% second-resolution (utc_datetime) and derived from the writer's clock, so
%% across nodes the fence margin absorbs clock skew; keep TTL well above the
%% renew interval. See ADR 0023.
save_snapshot_owned(Repo, Snapshot, Owner) ->
    #{run_id := RunId, updated_at := UpdatedAt} = Snapshot,
    Ttl = maps:get(lease_ttl_ms, Snapshot, 30000),
    ExpDt = system_time_datetime(UpdatedAt + Ttl),
    Fun = fun() ->
        Q0 = kura_query:from(gakudan_run_schema),
        Q1 = kura_query:where(Q0, {run_id, '=', RunId}),
        Q2 = kura_query:lock(Q1, ~"FOR UPDATE"),
        case kura_repo_worker:all(Repo, Q2) of
            {ok, []} ->
                insert_owned(Repo, Snapshot, Owner, ExpDt);
            {ok, [Existing]} ->
                case owns(maps:get(owner_id, Existing, undefined), Owner) of
                    true -> update_owned(Repo, Existing, Snapshot, Owner, ExpDt);
                    false -> lease_lost
                end;
            {error, _} = Err ->
                Err
        end
    end,
    try kura_repo_worker:transaction(Repo, Fun) of
        ok -> ok;
        lease_lost -> {error, lease_lost};
        {error, _} = Err -> Err;
        Other -> {error, {save_snapshot_failed, Other}}
    catch
        Class:Reason -> {error, {save_snapshot_failed, {Class, Reason}}}
    end.

insert_owned(Repo, Snapshot, Owner, ExpDt) ->
    #{run_id := RunId, status := Status, last_step := LastStep, updated_at := UpdatedAt} = Snapshot,
    Now = system_time_datetime(UpdatedAt),
    Changes = #{
        run_id => RunId,
        status => status_to_binary(Status),
        last_step => LastStep,
        data => term_to_binary(Snapshot),
        updated_at => Now,
        inserted_at => Now,
        owner_id => Owner,
        lease_expires_at => ExpDt
    },
    CS = kura_changeset:cast(
        gakudan_run_schema,
        #{},
        Changes,
        [run_id, status, last_step, data, updated_at, inserted_at, owner_id, lease_expires_at]
    ),
    normalise(kura_repo_worker:insert(Repo, CS)).

update_owned(Repo, Existing, Snapshot, Owner, ExpDt) ->
    #{status := Status, last_step := LastStep, updated_at := UpdatedAt} = Snapshot,
    Now = system_time_datetime(UpdatedAt),
    Changes = #{
        status => status_to_binary(Status),
        last_step => LastStep,
        data => term_to_binary(Snapshot),
        updated_at => Now,
        owner_id => Owner,
        lease_expires_at => ExpDt
    },
    CS = kura_changeset:cast(
        gakudan_run_schema,
        Existing,
        Changes,
        [status, last_step, data, updated_at, owner_id, lease_expires_at]
    ),
    normalise(kura_repo_worker:update(Repo, CS)).

owns(undefined, _Owner) -> true;
owns(null, _Owner) -> true;
owns(nil, _Owner) -> true;
owns(Owner, Owner) -> true;
owns(_Other, _Owner) -> false.

-spec load_snapshot(state(), gakudan:run_id()) ->
    {ok, gakudan_checkpointer:run_snapshot()} | {error, not_found | term()}.
load_snapshot(#{repo := Repo}, RunId) ->
    case kura_repo_worker:get(Repo, gakudan_run_schema, RunId) of
        {ok, #{data := Blob}} ->
            {ok, binary_to_term(Blob)};
        {error, _} = Err ->
            Err
    end.

-spec list_active(state()) -> {ok, [gakudan:run_id()]} | {error, term()}.
list_active(#{repo := Repo}) ->
    Active = [~"running", ~"idle", ~"awaiting_human"],
    Q0 = kura_query:from(gakudan_run_schema),
    Q1 = kura_query:where(Q0, {status, in, Active}),
    Q2 = kura_query:select(Q1, [run_id]),
    case kura_repo_worker:all(Repo, Q2) of
        {ok, Rows} -> {ok, [RunId || #{run_id := RunId} <- Rows]};
        {error, _} = Err -> Err
    end.

-spec delete_run(state(), gakudan:run_id()) -> ok | {error, term()}.
delete_run(#{repo := Repo}, RunId) ->
    StepQ = kura_query:where(kura_query:from(gakudan_step_schema), {run_id, '=', RunId}),
    _ = kura_repo_worker:delete_all(Repo, StepQ),
    ToolQ = kura_query:where(kura_query:from(gakudan_tool_result_schema), {run_id, '=', RunId}),
    _ = kura_repo_worker:delete_all(Repo, ToolQ),
    RunQ = kura_query:where(kura_query:from(gakudan_run_schema), {run_id, '=', RunId}),
    case kura_repo_worker:delete_all(Repo, RunQ) of
        {ok, _N} -> ok;
        {error, _} = Err -> Err
    end.

-spec save_step(state(), gakudan_checkpointer:step_record()) -> ok | {error, term()}.
save_step(#{repo := Repo}, Step) ->
    #{
        run_id := RunId,
        step_id := StepId,
        agent_id := AgentId,
        turn := Turn,
        usage := Usage,
        inserted_at := InsertedAt
    } = Step,
    Now = system_time_datetime(InsertedAt),
    Changes = #{
        step_id => StepId,
        run_id => RunId,
        agent_id => atom_to_binary(AgentId),
        turn => Turn,
        tokens_in => maps:get(input_tokens, Usage, 0),
        tokens_out => maps:get(output_tokens, Usage, 0),
        data => term_to_binary(Step),
        inserted_at => Now
    },
    CS = kura_changeset:cast(
        gakudan_step_schema,
        #{},
        Changes,
        [step_id, run_id, agent_id, turn, tokens_in, tokens_out, data, inserted_at]
    ),
    normalise(kura_repo_worker:insert(Repo, CS)).

-spec load_step(state(), gakudan:run_id(), binary()) ->
    {ok, gakudan_checkpointer:step_record()} | {error, not_found}.
load_step(#{repo := Repo}, _RunId, StepId) ->
    case kura_repo_worker:get(Repo, gakudan_step_schema, StepId) of
        {ok, #{data := Blob}} -> {ok, binary_to_term(Blob)};
        {error, not_found} = NF -> NF;
        {error, _} -> {error, not_found}
    end.

-spec save_tool_result(state(), gakudan_checkpointer:tool_result_record()) -> ok | {error, term()}.
save_tool_result(#{repo := Repo}, Record) ->
    #{
        run_id := RunId,
        tool_step_id := ToolStepId,
        agent_id := AgentId,
        turn := Turn,
        tool_name := ToolName,
        inserted_at := InsertedAt
    } = Record,
    Now = system_time_datetime(InsertedAt),
    Changes = #{
        tool_step_id => ToolStepId,
        run_id => RunId,
        agent_id => atom_to_binary(AgentId),
        turn => Turn,
        tool_name => ToolName,
        data => term_to_binary(Record),
        inserted_at => Now
    },
    CS = kura_changeset:cast(
        gakudan_tool_result_schema,
        #{},
        Changes,
        [tool_step_id, run_id, agent_id, turn, tool_name, data, inserted_at]
    ),
    normalise(kura_repo_worker:insert(Repo, CS)).

-spec load_tool_result(state(), gakudan:run_id(), binary()) ->
    {ok, gakudan_checkpointer:tool_result_record()} | {error, not_found}.
load_tool_result(#{repo := Repo}, _RunId, ToolStepId) ->
    case kura_repo_worker:get(Repo, gakudan_tool_result_schema, ToolStepId) of
        {ok, #{data := Blob}} -> {ok, binary_to_term(Blob)};
        {error, not_found} = NF -> NF;
        {error, _} -> {error, not_found}
    end.

-spec claim_runs(state(), gakudan_checkpointer:owner_id(), gakudan_checkpointer:claim_opts()) ->
    {ok, [gakudan_checkpointer:run_snapshot()]} | {error, term()}.
claim_runs(#{repo := Repo}, OwnerId, #{lease_ttl_ms := Ttl, limit := Limit}) ->
    NowMs = erlang:system_time(millisecond),
    NowDt = system_time_datetime(NowMs),
    ExpDt = system_time_datetime(NowMs + Ttl),
    Fun = fun() ->
        Active = [~"running", ~"idle", ~"awaiting_human"],
        Q0 = kura_query:from(gakudan_run_schema),
        Q1 = kura_query:where(Q0, {status, in, Active}),
        Q2 = kura_query:where(
            Q1, {'or', [{lease_expires_at, is_nil}, {lease_expires_at, '<', NowDt}]}
        ),
        Q3 = kura_query:order_by(Q2, [{updated_at, asc}]),
        Q4 = kura_query:limit(Q3, Limit),
        Q5 = kura_query:lock(Q4, ~"FOR UPDATE SKIP LOCKED"),
        case kura_repo_worker:all(Repo, Q5) of
            {ok, []} ->
                {ok, []};
            {ok, Rows} ->
                RunIds = [RunId || #{run_id := RunId} <- Rows],
                UQ = kura_query:where(
                    kura_query:from(gakudan_run_schema), {run_id, in, RunIds}
                ),
                Updates = #{owner_id => OwnerId, lease_expires_at => ExpDt},
                case kura_repo_worker:update_all(Repo, UQ, Updates) of
                    {ok, _} -> {ok, [binary_to_term(D) || #{data := D} <- Rows]};
                    {error, _} = Err -> Err
                end;
            {error, _} = Err ->
                Err
        end
    end,
    try kura_repo_worker:transaction(Repo, Fun) of
        {ok, Snaps} -> {ok, Snaps};
        {error, _} = Err -> Err;
        Other -> {error, {claim_failed, Other}}
    catch
        Class:Reason -> {error, {claim_failed, {Class, Reason}}}
    end.

-spec renew_leases(state(), gakudan_checkpointer:owner_id(), [gakudan:run_id()], pos_integer()) ->
    {ok, [gakudan:run_id()]} | {error, term()}.
renew_leases(_State, _OwnerId, [], _Ttl) ->
    {ok, []};
renew_leases(#{repo := Repo}, OwnerId, RunIds, Ttl) ->
    ExpDt = system_time_datetime(erlang:system_time(millisecond) + Ttl),
    UQ0 = kura_query:from(gakudan_run_schema),
    UQ1 = kura_query:where(UQ0, {run_id, in, RunIds}),
    UQ2 = kura_query:where(UQ1, {owner_id, '=', OwnerId}),
    case kura_repo_worker:update_all(Repo, UQ2, #{lease_expires_at => ExpDt}) of
        {ok, _} ->
            HQ0 = kura_query:from(gakudan_run_schema),
            HQ1 = kura_query:where(HQ0, {run_id, in, RunIds}),
            HQ2 = kura_query:where(HQ1, {owner_id, '=', OwnerId}),
            HQ3 = kura_query:select(HQ2, [run_id]),
            case kura_repo_worker:all(Repo, HQ3) of
                {ok, Rows} -> {ok, [R || #{run_id := R} <- Rows]};
                {error, _} = Err -> Err
            end;
        {error, _} = Err ->
            Err
    end.

-spec release_run(state(), gakudan_checkpointer:owner_id(), gakudan:run_id()) ->
    ok | {error, term()}.
release_run(#{repo := Repo}, OwnerId, RunId) ->
    Q0 = kura_query:from(gakudan_run_schema),
    Q1 = kura_query:where(Q0, {run_id, '=', RunId}),
    Q2 = kura_query:where(Q1, {owner_id, '=', OwnerId}),
    case kura_repo_worker:update_all(Repo, Q2, #{lease_expires_at => {{1970, 1, 1}, {0, 0, 0}}}) of
        {ok, _} -> ok;
        {error, _} = Err -> Err
    end.

normalise({ok, _}) -> ok;
normalise({error, _} = Err) -> Err.

status_to_binary(pending) -> ~"pending";
status_to_binary(running) -> ~"running";
status_to_binary(idle) -> ~"idle";
status_to_binary(awaiting_human) -> ~"awaiting_human";
status_to_binary(completed) -> ~"completed";
status_to_binary({error, _}) -> ~"error".

system_time_datetime(Ms) when is_integer(Ms) ->
    calendar:system_time_to_universal_time(Ms, millisecond).
