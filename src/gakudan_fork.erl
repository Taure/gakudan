-module(gakudan_fork).
-moduledoc """
Fork a new run from a checkpointed step of an existing run.

`gakudan:start_run(#{fork_from => {RunId, StepId}, ...})` rehydrates the
source run's persisted state as of the named step and continues it as a
brand-new run with its own id. The source run is untouched.

The fork point is precise: a step record stores the exact message history
the model saw at that step, and `gakudan_turn` maps blackboard entries to
those messages one-for-one, so the new run's blackboard is the source
transcript truncated to the entries that existed when the step ran. The new
run starts `idle`, ready to take new input or be driven by its router.

See [ADR 0021](docs/adr/0021-fork-from-checkpoint.md).
""".

-export([build_snapshot/3]).

-export_type([fork_point/0]).

-type fork_point() :: {gakudan:run_id(), StepId :: binary()}.

-doc """
Build a resume snapshot for a forked run from the source run's checkpointer
records. Returns the snapshot to hand to the runs supervisor's resume
path, keyed by `NewRunId`, or `{error, Reason}` if the source run or step
is not found.
""".
-spec build_snapshot({module(), term()}, fork_point(), gakudan:run_id()) ->
    {ok, gakudan_checkpointer:run_snapshot()} | {error, term()}.
build_snapshot(Handle, {SrcRunId, StepId}, NewRunId) ->
    case gakudan_checkpointer:load_snapshot(Handle, SrcRunId) of
        {ok, Snapshot} ->
            case gakudan_checkpointer:load_step(Handle, SrcRunId, StepId) of
                {ok, Step} ->
                    {ok, fork_snapshot(Snapshot, Step, NewRunId)};
                {error, not_found} ->
                    {error, {step_not_found, StepId}}
            end;
        {error, Reason} ->
            {error, {source_run_not_found, SrcRunId, Reason}}
    end.

-spec fork_snapshot(
    gakudan_checkpointer:run_snapshot(), gakudan_checkpointer:step_record(), gakudan:run_id()
) -> gakudan_checkpointer:run_snapshot().
fork_snapshot(Snapshot, Step, NewRunId) ->
    Entries = maps:get(blackboard, Snapshot, []),
    Truncated = truncate_to_step(Entries, Step),
    ForkedFrom = #{
        run_id => maps:get(run_id, Snapshot),
        step_id => maps:get(step_id, Step)
    },
    Config = fork_config(maps:get(config, Snapshot), NewRunId),
    maps:merge(Snapshot, #{
        run_id => NewRunId,
        status => idle,
        statem_state => idle,
        blackboard => Truncated,
        config => Config,
        fanout => undefined,
        forked_from => ForkedFrom,
        updated_at => erlang:system_time(millisecond)
    }).

%% The step's request carries the messages the model saw, one per blackboard
%% entry that preceded it; keep exactly that many oldest entries.
truncate_to_step(Entries, #{request := #{messages := Messages}}) when is_list(Messages) ->
    Keep = min(length(Messages), length(Entries)),
    lists:sublist(Entries, Keep);
truncate_to_step(Entries, _Step) ->
    Entries.

fork_config(Config, NewRunId) ->
    (maps:remove(fork_from, Config))#{run_id => NewRunId}.
