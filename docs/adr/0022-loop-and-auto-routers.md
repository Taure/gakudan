# 22. Loop and auto (LLM-select) routers

Date: 2026-06-01

## Status

Accepted.

## Context

The built-in routers covered fixed patterns: round-robin (cycle once or N
rounds), handoff (a fixed `@agent` baton), manager (one designated manager
always picks), and fanout (run all in parallel). Two common shapes were
missing:

- **Loop until a condition.** Refine-until-good, poll-until-ready, retry
  loops: run an agent (or a small cycle) repeatedly until some observable
  condition holds, with a guaranteed termination bound.
- **Open-ended LLM-select.** Let whichever agent just spoke choose who runs
  next, rather than routing through a single manager. Manager already does
  LLM-select but funnels every decision through one agent; a peer-to-peer
  "you decide who's next" pattern needs any speaker to steer.

Both are pure routing decisions expressible on the existing
`gakudan_router` behaviour, so they are new built-ins, not core changes.

## Decision

- **`gakudan_router_loop`** runs `agents` (default: all run agents), one per
  turn, cycling, until either an `until(Transcript) -> boolean()` predicate
  returns `true` or a `max_iterations` cap (default 10) is reached. The cap
  guarantees termination even with a predicate that never fires. The
  predicate observes transcript state (an agent wrote a sentinel, a
  blackboard value crossed a threshold), keeping the stop condition in the
  host's hands.
- **`gakudan_router_auto`** starts at `start` and, after each turn, scans
  the last speaker's text for `next: <agent_id>` (case-insensitive) to pick
  the next speaker, or `done` to end. An explicit `next:` wins over a `done`
  token so "my turn done. next: b" routes to b. With neither directive the
  run goes idle. An `agents` opt restricts the selectable set (default: all
  run agents).

## Consequences

**Positive.**

- The two most-requested missing control-flow shapes are now one-line config
  with no custom router.
- `loop` always terminates (the iteration cap is mandatory with a default),
  so a misbehaving predicate cannot hang a run.
- `auto` enables peer-to-peer routing that manager cannot express, while
  manager remains the right choice when a single coordinator should decide.

**Negative.**

- `auto` relies on agents emitting the `next:` / `done` convention in their
  text; a model that drifts from the convention stalls the run (goes idle).
  This is the same fragility as manager and handoff and is mitigated by a
  clear system prompt; a structured-output directive (ADR 0017) could make
  it robust later.
- Both routers decide purely on the transcript, so a predicate or directive
  that depends on blackboard kv must have an agent surface that state into
  the transcript first.
