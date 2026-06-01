# 21. Fork from checkpoint

Date: 2026-06-01

## Status

Accepted. Builds on [ADR 0003](0003-checkpointer-behaviour.md) and
[ADR 0004](0004-resume-interrupt-idempotency.md).

## Context

The checkpointer already persists a run's snapshot plus an append-only step
record per LLM call, which powers crash-recovery and idempotent resume. The
same records support a different operation: branching. Given a run that
reached some step, you may want to explore an alternative continuation -
a different prompt, a different router, a what-if - without disturbing the
original run or losing its history. This is "fork from a checkpoint".

Resume already rehydrates a run into the same run id. Forking needs the
same rehydration but into a *new* run id, anchored at a chosen step rather
than the latest snapshot, leaving the source run untouched.

## Decision

- **Add `start_run(#{fork_from => {SourceRunId, StepId}})`.** It loads the
  source run's snapshot and the named step from the checkpointer, builds a
  resume snapshot keyed by a fresh run id, and starts it through the
  existing runs-supervisor resume path. The source run is never
  read-modified, so it is unaffected.
- **The fork point is precise.** A step record stores the exact message
  history the model saw at that step, and `gakudan_turn` maps blackboard
  entries to those messages one-for-one. So the forked blackboard is the
  source transcript truncated to the entries that existed when the step
  ran (`lists:sublist(Entries, length(StepMessages))`). The fork continues
  from that point, not from the source run's final state.
- **The new run starts `idle`**, ready to take new input or be driven by
  its router, and carries a `forked_from => #{run_id, step_id}` marker for
  provenance. This adds one optional key to the `gakudan_checkpointer`
  `run_snapshot()` type - a backward-compatible map extension.
- **Forking requires a checkpointer** (config `checkpointer` or the
  `default_checkpointer` env); without one it returns `{error,
  no_checkpointer}`. A missing source run or step returns a descriptive
  `{error, _}`.
- **The logic lives in `gakudan_fork`**, a small pure-ish module
  (`build_snapshot/3`); `gakudan:start_run/1` only wires it to the
  checkpointer and the runs supervisor, so core orchestration is unchanged.

## Consequences

**Positive.**

- Branching / what-if exploration falls out of the existing persistence
  records with no new storage and no change to the run loop.
- The forked run reuses the whole resume machinery, so its lifecycle,
  telemetry, and idempotency behave like any other run.
- Provenance is recorded; a fork is traceable back to its origin step.

**Negative.**

- Fidelity of the truncation depends on the 1:1 entry-to-message mapping in
  `gakudan_turn`. A future change to how transcripts become messages would
  need to keep that mapping (or store an explicit entry boundary per step)
  to keep forks precise; the fallback keeps all entries if the step lacks
  messages.
- The fork shares no step / tool-result cache with the source run (records
  are keyed by run id), so the new run re-executes from the fork point
  rather than replaying the source's later cached steps. That is the
  intended semantics for a branch, but means a fork is not free if it
  retraces ground the source already covered.
- Forking does not copy per-tool side effects the source performed after
  the fork point; a forked run that re-runs such tools repeats their
  effects. Tools with external side effects should be idempotent or
  fork-aware.
