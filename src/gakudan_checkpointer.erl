-module(gakudan_checkpointer).
-moduledoc """
Persistence behaviour for runs and per-step LLM records.

See ADR 0003 for the contract this locks in, and ADR 0004 for the
resume / interrupt / idempotency semantics that hang off it.

An implementation owns a `t:state/0` (a kura repo name, a file path,
whatever it needs). The library never inspects it.

Two collections live in this contract:

- **Snapshots** are the resumable view of a run at a moment in time.
  Overwritten in place every meaningful state transition.
- **Step records** are append-only per LLM call. They power idempotent
  resume and double as a cost / audit ledger.
- **Tool-result records** are append-only per executed tool call. On
  resume, a cached result is replayed instead of re-running the tool, so
  side effects are exactly-once at the library boundary (ADR 0009).
""".

-export([
    init/2,
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

-export_type([
    state/0, run_snapshot/0, step_record/0, tool_result_record/0, run_status/0, owner_id/0
]).

-type state() :: term().

-type owner_id() :: binary().

-type run_status() ::
    pending
    | running
    | idle
    | awaiting_human
    | completed
    | {error, term()}.

-type run_snapshot() :: #{
    run_id := gakudan:run_id(),
    status := run_status(),
    config := gakudan:run_config(),
    last_step := non_neg_integer(),
    blackboard := [gakudan_blackboard:entry()],
    kv := #{atom() => term()},
    router_state := term(),
    statem_state := atom(),
    turn := non_neg_integer(),
    fanout => undefined | #{base := non_neg_integer(), agents := [atom()]},
    forked_from => #{run_id := gakudan:run_id(), step_id := binary()},
    owner => owner_id(),
    lease_ttl_ms => pos_integer(),
    updated_at := integer()
}.

-type step_record() :: #{
    run_id := gakudan:run_id(),
    step_id := binary(),
    agent_id := atom(),
    turn := non_neg_integer(),
    request := term(),
    response := term(),
    usage := gakudan_llm:usage(),
    inserted_at := integer()
}.

-type tool_result_record() :: #{
    run_id := gakudan:run_id(),
    tool_step_id := binary(),
    agent_id := atom(),
    turn := non_neg_integer(),
    tool_name := binary(),
    output := term(),
    inserted_at := integer()
}.

-type claim_opts() :: #{lease_ttl_ms := pos_integer(), limit := pos_integer()}.

-export_type([claim_opts/0]).

-callback init(Opts :: map()) -> {ok, state()} | {error, term()}.
-callback save_snapshot(state(), run_snapshot()) -> ok | {error, lease_lost | term()}.
-callback load_snapshot(state(), gakudan:run_id()) ->
    {ok, run_snapshot()} | {error, not_found | term()}.
-callback list_active(state()) -> {ok, [gakudan:run_id()]} | {error, term()}.
-callback delete_run(state(), gakudan:run_id()) -> ok | {error, term()}.
-callback save_step(state(), step_record()) -> ok | {error, term()}.
-callback load_step(state(), gakudan:run_id(), StepId :: binary()) ->
    {ok, step_record()} | {error, not_found}.
-callback save_tool_result(state(), tool_result_record()) -> ok | {error, term()}.
-callback load_tool_result(state(), gakudan:run_id(), ToolStepId :: binary()) ->
    {ok, tool_result_record()} | {error, not_found}.

%% Optional, for horizontal scale-out (ADR 0023). A backend that does not
%% implement these supports single-node operation only; the lease wrappers
%% below return `{error, not_supported}`.
-callback claim_runs(state(), owner_id(), claim_opts()) ->
    {ok, [run_snapshot()]} | {error, term()}.
-callback renew_leases(state(), owner_id(), [gakudan:run_id()], LeaseTtlMs :: pos_integer()) ->
    {ok, Held :: [gakudan:run_id()]} | {error, term()}.
-callback release_run(state(), owner_id(), gakudan:run_id()) -> ok | {error, term()}.

-optional_callbacks([claim_runs/3, renew_leases/4, release_run/3]).

-doc "Initialise a checkpointer impl. Returns its opaque state handle.".
-spec init(module(), map()) -> {ok, {module(), state()}} | {error, term()}.
init(Mod, Opts) ->
    case Mod:init(Opts) of
        {ok, State} -> {ok, {Mod, State}};
        {error, _} = Err -> Err
    end.

-doc "Persist a snapshot. Telemetry-wrapped.".
-spec save_snapshot({module(), state()}, run_snapshot()) -> ok | {error, term()}.
save_snapshot({Mod, State}, Snapshot) ->
    #{run_id := RunId} = Snapshot,
    Bytes = erlang:external_size(Snapshot),
    StartMeta = #{run_id => RunId, kind => snapshot},
    telemetry:span(
        [gakudan, checkpoint, save],
        StartMeta,
        fun() ->
            Result = Mod:save_snapshot(State, Snapshot),
            {Result, #{bytes => Bytes}, stop_meta(StartMeta, Result)}
        end
    ).

-doc "Load a snapshot by run_id. Telemetry-wrapped.".
-spec load_snapshot({module(), state()}, gakudan:run_id()) ->
    {ok, run_snapshot()} | {error, not_found | term()}.
load_snapshot({Mod, State}, RunId) ->
    StartMeta = #{run_id => RunId, kind => snapshot},
    telemetry:span(
        [gakudan, checkpoint, load],
        StartMeta,
        fun() ->
            Result = Mod:load_snapshot(State, RunId),
            {Result, #{}, load_stop_meta(StartMeta, Result)}
        end
    ).

-doc "List run_ids whose status is one of running, idle, awaiting_human.".
-spec list_active({module(), state()}) -> {ok, [gakudan:run_id()]} | {error, term()}.
list_active({Mod, State}) ->
    Mod:list_active(State).

-doc "Delete all snapshot + step records for a run.".
-spec delete_run({module(), state()}, gakudan:run_id()) -> ok | {error, term()}.
delete_run({Mod, State}, RunId) ->
    Mod:delete_run(State, RunId).

-doc "Persist an LLM step record. Telemetry-wrapped.".
-spec save_step({module(), state()}, step_record()) -> ok | {error, term()}.
save_step({Mod, State}, Step) ->
    #{run_id := RunId} = Step,
    Bytes = erlang:external_size(Step),
    StartMeta = #{run_id => RunId, kind => step},
    telemetry:span(
        [gakudan, checkpoint, save],
        StartMeta,
        fun() ->
            Result = Mod:save_step(State, Step),
            {Result, #{bytes => Bytes}, stop_meta(StartMeta, Result)}
        end
    ).

-doc "Look up a step record by (run_id, step_id). Telemetry-wrapped.".
-spec load_step({module(), state()}, gakudan:run_id(), binary()) ->
    {ok, step_record()} | {error, not_found}.
load_step({Mod, State}, RunId, StepId) ->
    StartMeta = #{run_id => RunId, kind => step},
    telemetry:span(
        [gakudan, checkpoint, load],
        StartMeta,
        fun() ->
            Result = Mod:load_step(State, RunId, StepId),
            {Result, #{}, load_stop_meta(StartMeta, Result)}
        end
    ).

-doc "Persist a tool-result record for exactly-once replay. Telemetry-wrapped.".
-spec save_tool_result({module(), state()}, tool_result_record()) -> ok | {error, term()}.
save_tool_result({Mod, State}, Record) ->
    #{run_id := RunId} = Record,
    Bytes = erlang:external_size(Record),
    StartMeta = #{run_id => RunId, kind => tool_result},
    telemetry:span(
        [gakudan, checkpoint, save],
        StartMeta,
        fun() ->
            Result = Mod:save_tool_result(State, Record),
            {Result, #{bytes => Bytes}, stop_meta(StartMeta, Result)}
        end
    ).

-doc "Look up a tool-result record by (run_id, tool_step_id). Telemetry-wrapped.".
-spec load_tool_result({module(), state()}, gakudan:run_id(), binary()) ->
    {ok, tool_result_record()} | {error, not_found}.
load_tool_result({Mod, State}, RunId, ToolStepId) ->
    StartMeta = #{run_id => RunId, kind => tool_result},
    telemetry:span(
        [gakudan, checkpoint, load],
        StartMeta,
        fun() ->
            Result = Mod:load_tool_result(State, RunId, ToolStepId),
            {Result, #{}, load_stop_meta(StartMeta, Result)}
        end
    ).

-doc """
Atomically claim active runs that are unowned or whose lease has expired,
marking them owned by `OwnerId`, and return their snapshots. The basis for
horizontal scale-out (ADR 0023). Returns `{error, not_supported}` if the
backend does not implement leasing.
""".
-spec claim_runs({module(), state()}, owner_id(), claim_opts()) ->
    {ok, [run_snapshot()]} | {error, not_supported | term()}.
claim_runs({Mod, State}, OwnerId, Opts) ->
    case erlang:function_exported(Mod, claim_runs, 3) of
        true -> Mod:claim_runs(State, OwnerId, Opts);
        false -> {error, not_supported}
    end.

-doc """
Extend the lease on the runs `OwnerId` still owns, returning the subset it
actually still holds. Runs absent from the returned list have been lost to
another owner and must be fenced. Returns `{error, not_supported}` if the
backend does not implement leasing.
""".
-spec renew_leases({module(), state()}, owner_id(), [gakudan:run_id()], pos_integer()) ->
    {ok, [gakudan:run_id()]} | {error, not_supported | term()}.
renew_leases({Mod, State}, OwnerId, RunIds, LeaseTtlMs) ->
    case erlang:function_exported(Mod, renew_leases, 4) of
        true -> Mod:renew_leases(State, OwnerId, RunIds, LeaseTtlMs);
        false -> {error, not_supported}
    end.

-doc """
Release ownership of a run so another node can claim it immediately, used on
graceful shutdown. Returns `{error, not_supported}` if the backend does not
implement leasing.
""".
-spec release_run({module(), state()}, owner_id(), gakudan:run_id()) ->
    ok | {error, not_supported | term()}.
release_run({Mod, State}, OwnerId, RunId) ->
    case erlang:function_exported(Mod, release_run, 3) of
        true -> Mod:release_run(State, OwnerId, RunId);
        false -> {error, not_supported}
    end.

stop_meta(StartMeta, ok) -> StartMeta#{outcome => ok};
stop_meta(StartMeta, {error, Reason}) -> StartMeta#{outcome => error, reason => Reason}.

load_stop_meta(StartMeta, {ok, _}) -> StartMeta#{outcome => ok};
load_stop_meta(StartMeta, {error, not_found}) -> StartMeta#{outcome => not_found};
load_stop_meta(StartMeta, {error, Reason}) -> StartMeta#{outcome => error, reason => Reason}.
