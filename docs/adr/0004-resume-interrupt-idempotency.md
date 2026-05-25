# 4. Resume, interrupt, and step idempotency

Date: 2026-05-25

## Status

Accepted (v0.2).

## Context

ADR 0003 locks the persistence contract: snapshots survive restarts, step
records survive forever. This ADR locks the **runtime semantics** that
hang off that contract:

- How a run is resumed after a BEAM restart.
- How a run is paused to wait for a human (or any out-of-band signal)
  and resumed later.
- What guarantees we make about not double-billing LLM calls or
  double-executing tool calls when a run replays from a snapshot.

These are the questions a regulated operator (Kivra-shaped buyer) will
ask before adopting gakudan in any production-grade path. Answering
them in code, not in marketing, is the v0.2 differentiator.

## Decision

### Resume on app start

`gakudan_runs_resumer` is a transient gen_server started by
`gakudan_sup`, after the registry and `gakudan_runs_sup`, ordered last
so the supervisor tree is ready when it runs.

On `init/1` it:

1. Reads the configured default checkpointer (`{gakudan,
   default_checkpointer}` in app env), or skips if none is set.
2. Calls `Checkpointer:list_active(State)` to enumerate runs whose
   `status` is one of `running`, `idle`, or `awaiting_human`.
3. For each, loads the snapshot via `Checkpointer:load_snapshot/2`
   and calls `gakudan_runs_sup:resume_run(Snapshot)`.

`resume_run/1` is a new entrypoint on `gakudan_runs_sup` that spawns
the run supervisor tree with a `{resume, Snapshot}` start mode instead
of `{fresh, Config}`. The run supervisor passes that through to
`gakudan_blackboard` (rehydrate from `entries` + `kv`) and to
`gakudan_run_statem` (rehydrate `router_state`, `turn`, `statem_state`).

Runs in state `completed` or `{error, _}` are not resumed; they remain
queryable via the checkpointer for audit.

A failed resume (snapshot present but invalid, e.g. configured agent
module no longer compiled) logs at `error` level via `?LOG_ERROR`,
emits `[gakudan, resume, failed]`, marks the run as `{error,
resume_failed}` in the checkpointer, and continues with the next run.
One bad snapshot must not block the rest.

### Awaiting-human as a first-class state

`gakudan_run_statem` gains a new state `awaiting_human`. Entered via
the new `gakudan:interrupt/2` API:

```erlang
gakudan:interrupt(RunId, Reason :: term()) -> ok | {error, not_found}.
gakudan:resume(RunId, Payload :: term()) -> ok | {error, not_found | not_interrupted}.
```

Semantics:

- `interrupt/2` is valid in state `idle` or `running`. From `running`,
  the current turn worker is allowed to finish (its result is recorded
  normally); the statem transitions to `awaiting_human` instead of
  picking the next agent. From `idle`, the transition is immediate.
- `interrupt/2` writes a `system`-role entry to the blackboard:
  `<<"interrupted: ", Reason/binary>>` (or a `term_to_binary`-encoded
  Erlang term if `Reason` is not a binary, prefixed). Audit-friendly.
- `resume/2` is valid only in `awaiting_human`. It writes a
  `user`-role entry containing `Payload` (binary as-is; non-binary
  encoded via `io_lib:format("~p", [...])`), then transitions back to
  `running` and dispatches the next turn via the router as normal.
- Both calls trigger a snapshot save.

### Step-id idempotency for LLM calls

Each LLM call inside a turn worker is keyed by a deterministic
`step_id`:

```
step_id = blake2b_hex(
    iolist_to_binary([
        RunId, $|,
        integer_to_binary(Turn), $|,
        atom_to_binary(AgentId), $|,
        integer_to_binary(IterationWithinTurn)
    ])
)
```

`IterationWithinTurn` is 0 for the first LLM call inside a turn and
increments per tool-loop iteration (see `gakudan_turn:loop/11`).

Before issuing an LLM request, the turn worker calls
`gakudan_checkpointer:load_step/3`. If a step record exists with the
same `step_id`, the persisted response is returned directly and no
network call is made. After a successful response, the worker calls
`gakudan_checkpointer:save_step/2` with the request/response pair.

This means a run that replays from snapshot will:

1. Restart the turn worker for the (interrupted) current turn from
   `IterationWithinTurn = 0`.
2. For each iteration that already completed before the crash, hit
   the cache and return the persisted response in microseconds.
3. For the iteration that was in-flight at crash time, re-issue the
   LLM request (this **may** double-bill that one request, depending
   on whether the provider charged for the original).
4. Continue normally from there.

The worst case is one re-issued LLM request per resume, not a full
turn re-run.

### Tool calls are not idempotent by the library

We do not cache tool call outputs. A tool that runs `kura_repo:insert/2`
will run it again if the turn re-executes after a crash. Tool authors
who care must implement idempotency themselves (deterministic IDs,
upserts, idempotency keys). The library documents this and the
`gakudan_tool` behaviour gains a `is_idempotent/0` optional callback so
authors can self-declare; in v0.2 this callback is informational only
(no enforcement). v0.3 may use it to gate replay.

### Snapshot triggers

A snapshot is written:

- After `finish_init` completes (`status = idle`, `last_step = 0`).
- After every blackboard `append` (the blackboard fires
  `{checkpoint_request, Snapshot}` to the run statem, which writes
  asynchronously via `cast` to a per-run save worker; the run statem
  does not block on disk I/O).
- After every turn completes (`turn_complete` or `turn_failed`).
- On entry to and exit from `awaiting_human`.
- On `terminate/3` if the reason is `normal` or `shutdown` (clean stop
  marks `status = completed`).

Crash-during-save is acceptable: the next save (or the next boot's
`load_snapshot/2`) returns the previous good snapshot. Step records
are independent and never partially written (single insert per step).

### Telemetry

Three new events extend ADR 0001:

#### `[gakudan, checkpoint, save, start | stop | exception]`

`telemetry:span/3` around the checkpointer's `save_snapshot/2`.

- Span metadata: `#{run_id, kind := snapshot | step}`
- Stop measurements (added to `duration`): `#{bytes := non_neg_integer()}`
- Stop metadata (added): `#{outcome := ok | error, reason => term()}`

#### `[gakudan, checkpoint, load, start | stop | exception]`

`telemetry:span/3` around `load_snapshot/2` and `load_step/3`.

- Span metadata: `#{run_id, kind := snapshot | step}`
- Stop metadata (added): `#{outcome := ok | error | not_found, reason => term()}`

#### `[gakudan, resume, attempted | succeeded | failed]`

`telemetry:execute/3`. Emitted once per run during boot resume.

- Measurements: `#{system_time := integer()}`
- Metadata: `#{run_id, outcome := succeeded | failed, reason => term()}`

## Consequences

**Positive.**

- The "BEAM restarts mid-run" failure mode goes from "lose work" to
  "resume from the last successful step." This is the single biggest
  competitive gap closed by v0.2.
- Human-in-the-loop is a first-class state, not a workaround pattern
  layered on top of `running`.
- Cost of resume is bounded: at most one re-issued LLM call per
  resume, not a full turn re-run.
- Audit story is real: every LLM call has a step record with
  request, response, and token counts.

**Negative.**

- The turn worker becomes slightly heavier: each LLM call gains a
  load-step lookup and a save-step write. On the hot path (no resume),
  this is two extra DB round-trips per LLM request. Default backend is
  kura, so this is ~1-3ms per request against local Postgres / SQLite.
- Idempotency is best-effort, not absolute: a crash between
  "LLM responded" and "step saved" still re-bills that one call on
  resume. We accept this; eliminating it requires a distributed-
  transaction story we are not building in v0.2.
- Tool authors carry the idempotency burden. Documented prominently;
  enforcement is a v0.3 question.
- The `awaiting_human` state adds public API surface
  (`interrupt/2`, `resume/2`). These are stable from v0.2 forward.