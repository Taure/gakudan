# 9. Tool idempotency and supervised resume

Date: 2026-05-26

## Status

Accepted (v0.4). Implemented in two parts: **tool idempotency** (Part 1)
and **supervised resume** (Part 2).

## Context

ADR 0004 gave gakudan two things: human-in-the-loop interrupt/resume,
and idempotent **LLM** replay (a step record keyed by
`hash(run_id | turn | agent_id | iter)` so a resumed run serves
completed model calls from cache instead of re-billing them). It also
stated two deliberate limits that the 2026 landscape now makes worth
revisiting:

1. **Tool calls are not idempotent.** On resume, a turn re-runs; its
   LLM steps are cached, but any tool it calls executes again. A tool
   that posts a GitHub comment, charges a card, or sends mail will do so
   twice.
2. **A crashed run is not recovered until the next BEAM boot.** The
   per-run supervisor's children restart together (`one_for_all`), but a
   restarted `gakudan_run_statem` starts `{fresh, Config}` and loses its
   state, so in practice a mid-run crash is unrecoverable while the node
   stays up. `gakudan_runs_resumer` only sweeps active runs at
   application start. "Resumable" today therefore means "survives a full
   restart," not "survives a process crash."

The durable-execution world (Temporal, DBOS, Restate) has made
exactly-once side effects and transparent crash recovery the bar for
"reliable agent." Pydantic AI and the OpenAI Agents SDK reach it by
delegating to those engines. gakudan can reach the single-node version
of it natively, because it already has the checkpointer seam and the OTP
supervision tree - the two missing pieces compose with machinery that
exists.

Scope note: this is **single-node** exactly-once, consistent with the
project's standing non-goal of multi-node distribution. Cross-node
exactly-once stays out.

## Decision

### Part 1 - tool result caching (exactly-once at the gakudan boundary)

Extend the checkpointer with tool-result records, mirroring step
records:

```erlang
-callback save_tool_result(state(), tool_result_record()) -> ok | {error, term()}.
-callback load_tool_result(state(), run_id(), tool_step_id()) ->
    {ok, tool_result_record()} | {error, not_found}.

tool_step_id() :: binary(). %% hash(run_id | turn | agent_id | iter | tool_use_id)
```

In `gakudan_turn`, before invoking a tool, compute `tool_step_id` and
consult the cache; on hit, return the stored result and **skip the
call**; on miss, run the tool and persist the result. The `tool_use_id`
comes from the model response, which is itself cached by ADR 0004, so
on replay the same `tool_use_id` reappears and the key is stable.

This makes side effects exactly-once **at the boundary gakudan
controls**: on resume we never re-invoke a tool whose result we already
have. It does not make a tool's own internal effects transactional - a
crash *during* the tool call, before the result is persisted, still
re-runs it. That residual window is the same one Temporal documents for
non-transactional activities, and we document it the same way.

Caching is on whenever a checkpointer is configured. A tool that must
run every time (rare - e.g. "read current sensor value") opts out via a
new optional callback:

```erlang
-callback idempotent() -> boolean(). %% default true
```

### Part 2 - supervised resume (self-healing runs)

Make a crashed run recover from its last snapshot without waiting for a
reboot, by unifying boot-time and runtime recovery behind one rule:
**a run statem always rehydrates from the checkpointer on init.**

- The `gakudan_run_statem` `init/1` callback, when a checkpointer is configured, loads
  the latest snapshot for its `run_id`. If one exists, it resumes from
  it; only with no snapshot does it start fresh. Supervised restart thus
  resumes automatically instead of starting blank.
- Only an **active** snapshot (`running` / `idle` / `awaiting_human`)
  triggers a resume; a `completed` or errored snapshot is ignored and
  the run starts fresh.
- `gakudan_runs_sup` starts each per-run supervisor as `transient`, so
  an abnormal exit is restarted (a normal / `completed` / `shutdown`
  exit is not).
- Restart thrash is self-bounding: a run that deterministically crashes
  exhausts the per-run supervisor's `intensity`, which makes that
  supervisor exit with reason `shutdown`. Because the parent treats the
  child as `transient`, a `shutdown` exit is **not** restarted, so the
  run stops cleanly without cascading to the application. The snapshot
  stays in its last state, recoverable at the next boot.

`gakudan_runs_resumer` is unchanged in spirit but becomes the
boot-time entry to the same "load snapshot, resume" path the supervisor
now uses at runtime.

Two implementation notes. First, the **blackboard is restored by the
statem**, not the supervisor: both the fresh and resume specs start an
empty blackboard, and the statem repopulates it from the snapshot via
`gakudan_blackboard:restore/2`. This is what makes a `one_for_all`
restart safe (the blackboard is wiped on restart, then rebuilt from the
snapshot), and it also fixed a latent bug where the resume spec never
started the per-run `stream` process. Second, resume does **not**
auto-continue an in-flight turn: a resumed run re-enters `idle` (or
`awaiting_human`) and continues on the next message. Re-dispatching a
mid-turn fanout on resume is safe given the idempotency above, but is
left as a later refinement.

## Consequences

**Positive.**

- Single-node durable-execution semantics: LLM calls and tool side
  effects are exactly-once across both process crash and full restart,
  using the checkpointer that already exists.
- Runs self-heal. A turn worker or statem crash no longer strands a run
  until reboot; it restarts from the last snapshot within the
  supervisor's budget.
- No new subsystem - tool caching reuses the step-record pattern, and
  supervised resume reuses the existing `{resume, Config, Snapshot}`
  init path. Stays inside the "primitives, not a framework" line.

**Negative / limits.**

- **Storage growth.** Every tool result is persisted alongside every LLM
  step. Retention/cleanup remains the caller's responsibility (gakudan
  has never owned a GC policy); `delete_run/2` already exists for it.
- **Residual at-least-once window.** A crash after a tool's side effect
  but before its result is persisted re-runs the tool. True
  transactional tools (effect + checkpoint in one commit) are out of
  scope on a single node without a shared transaction; documented, not
  hidden.
- **Restart thrash vs. data loss tension.** `transient` + bounded
  intensity is the chosen balance: self-heal transient faults, give up
  on deterministic ones. Tuning those numbers is a follow-up once real
  failure data exists.
- Requires a checkpointer schema migration (new tool-result table) and
  two new behaviour callbacks; existing checkpointer implementations
  must add them. The in-memory test checkpointer and `..._kura` ship
  with the change.
