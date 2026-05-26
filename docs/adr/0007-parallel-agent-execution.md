# 7. Parallel agent execution via router fanout

Date: 2026-05-26

## Status

Accepted (v0.4).

## Context

Through v0.3 a run executes agents strictly one at a time. The run
state machine asks the router for the next agent, spawns a single turn
worker, and waits for it before asking again. The router contract is:

```erlang
-callback next(state(), Transcript :: [entry()]) ->
    {next, gakudan_agent:id(), state()} | {done, state()}.
```

This is the one place gakudan leaves performance on the table that the
BEAM hands us for free. Whole classes of multi-agent topology are
inherently parallel:

- **Ensemble / poll.** Ask N agents the same question, then aggregate.
- **Map step.** Fan a task out to N workers, each on its own slice.
- **Speculative critique.** Run a drafter and several independent
  critics at once, then reconcile.

Every one of these is currently serialised. On a runtime built for
millions of isolated processes, running three agents sequentially
because the API only models one next-agent is the wrong default.
Competing frameworks (Google ADK `ParallelAgent`, LangGraph parallel
super-steps, Strands swarm) all ship parallel fan-out; ours would be
genuinely better because each branch is a real supervised process with
real isolation, not a coroutine on one event loop.

The constraint: this must not become a workflow DSL (see CLAUDE.md
design pillars). Parallelism has to fall out of the existing router +
turn machinery, not a new graph layer.

## Decision

### One new router return: `fanout`

The `gakudan_router` `next/2` callback gains a third return shape:

```erlang
-callback next(state(), Transcript :: [entry()]) ->
      {next, gakudan_agent:id(), state()}
    | {fanout, [gakudan_agent:id()], state()}
    | {done, state()}.
```

`{fanout, AgentIds, State}` means: run every agent in `AgentIds`
concurrently against the current transcript, and call `next/2` again
only once **all** of them have finished and their outputs are on the
blackboard.

This is the entire public surface of the feature. `{next, A, S}` is now
defined as exactly equivalent to `{fanout, [A], S}`; the single-agent
path is the degenerate fanout of one. Existing routers never emit
`fanout` and are unaffected (backwards compatible).

### Why this is safe with the existing turn worker

A turn worker appends to the blackboard exactly once, at the very end
of its tool loop (`gakudan_turn` only calls `gakudan_blackboard:append`
after the model returns `end_turn`; tool results live in the worker's
local message list, never on the blackboard). Therefore all agents in a
fanout, spawned together before any of them has produced output, read
an **identical** pre-fanout transcript. No frozen-snapshot plumbing is
required for correctness; the append-once property already guarantees
it. The turn worker is reused unchanged.

### State machine changes

The single `turn_worker` field becomes a map of outstanding workers:

```erlang
turn_workers :: #{reference() => #{pid, agent_id, turn, start_time}}
fanout       :: undefined | #{base := non_neg_integer(), size := pos_integer()}
```

Dispatch (`{next,...}` and `{fanout,...}` both route here):

1. Capture `Base = Data#data.turn`.
2. For the i-th agent (1-indexed) in the list, assign turn number
   `Base + i`, emit `[gakudan, turn, start]`, and `spawn_monitor` a
   worker that runs the `gakudan_turn` entrypoint and replies `{turn_done, Pid}`
   or `{turn_failed, Pid, Reason}`.
3. Persist a snapshot with `status = running` and **`turn = Base`**
   (pre-fanout), then enter `running`.

Completion: on each `{turn_done, Pid}` / `{turn_failed, Pid, Reason}` /
abnormal `{'DOWN', _, process, Pid, _}`, emit `[gakudan, turn, stop]`,
drop `Pid` from `turn_workers` (the monitor ref lives in the worker
entry, so a completed worker is demonitored with `flush`). A failed
member appends a `system` error entry
(unchanged from the single-turn behaviour) but does **not** cancel its
siblings. When `turn_workers` becomes empty:

1. Set `turn = Base + size`.
2. If `should_continue/1` (turn budget) holds, snapshot `running` and
   re-consult the router; otherwise snapshot `idle` and go `idle`.

### Turn numbering and the budget

Each dispatched agent execution consumes one turn, exactly as today. A
fanout of N advances the turn counter by N and counts N against
`max_turns`. This keeps `max_turns` an honest bound on total LLM work
and keeps per-agent turn numbers unique, so the ADR 0004 step id
(`hash(run_id | turn | agent_id | iter)`) stays collision-free across a
fanout without any change. `max_turns` is checked between fanouts, never
mid-fanout: a fanout the router asked for always runs in full.

### Resume interaction

The dispatch-time snapshot records the **pre-fanout** blackboard and
turn counter. A crash anywhere inside a fanout therefore rewinds to "the
router is about to be consulted." On resume the router (its state also
restored) returns the same ordered fanout, every member re-runs, and
each member's already-completed LLM steps are served from the ADR 0004
cache. Members that had appended before the crash do not double-append,
because their appends were never persisted (no snapshot was taken
mid-fanout). Net: resume is exactly as clean as the single-turn case,
and reuses the same idempotency machinery.

### Built-in router

`gakudan_router_fanout` ships as the parallel analogue of
`gakudan_router_round_robin`: each `next/2` returns
`{fanout, AllAgents, State}` for `rounds` rounds (default 1), then
`done`. It is the smallest useful demonstration (parallel ensemble) and
documents the contract by example.

## Consequences

**Positive.**

- Ensemble, map, and speculative-critique topologies run in true
  parallel, each branch an isolated supervised process. This is the
  BEAM differentiator made real, not a comparison-table checkbox.
- Zero churn for existing users: `{next, A, S}` semantics are
  unchanged, existing routers compile and behave identically.
- No new abstraction. Parallelism is one extra return value on a
  behaviour that already exists. The design pillars hold.
- Reuses ADR 0004 idempotency wholesale; resume needed no new concept.

**Negative / deferred.**

- **Append order within a fanout is completion order, not list order.**
  Aggregating routers must key on `{agent, AgentId}` rather than
  position. Deterministic ordering (statem collects then appends in
  list order) is a possible v0.5 refinement and would require the turn
  worker to return its text instead of self-appending; deferred until a
  consumer needs it.
- **Interrupting mid-fanout does not cancel in-flight workers.** As in
  the single-turn case today, an `interrupt/2` during a fanout lets
  running turns finish; their appends may land after the interrupt
  entry. Documented; killing branches on interrupt is deferred.
- **No fanout-level concurrency cap.** A router that fans out to 1000
  agents starts 1000 turn workers and 1000 concurrent LLM calls.
  Backpressure / a `max_parallel` knob is a future addition if a
  consumer hits provider rate limits; for now it is the router author's
  responsibility.

### Stability

The `fanout` return variant and `gakudan_router_fanout` are stable from
v0.4 onward under semver. Because `{next, _, _}` is preserved, this is a
minor (additive) change to the router contract.
