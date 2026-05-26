# 13. Cost budgets

Date: 2026-05-26

## Status

Accepted (v0.5).

## Context

gakudan already meters spend: `[gakudan, llm, request, stop]` carries
`tokens_in` / `tokens_out`, so per-run and per-team cost is *observable*. What
it cannot do is *enforce* a cap. A runaway agent loop, a prompt-injection that
goads a model into a long tool chain, or simply an expensive task can burn an
unbounded amount before anyone looks at a dashboard. For the regulated rollout
this library backs, an operator needs a hard ceiling: stop the run before it
spends past a limit, not after.

`max_turns` is the only existing brake, and it counts turns, not cost - a
single turn can make up to `?MAX_TOOL_ITERATIONS` LLM calls. So a budget is a
distinct, orthogonal control.

The usual tension applies. Token caps are a universal, non-opinionated
primitive (a token is a token). Money is *not* - prices vary by provider,
model, contract, and time, and a per-tenant cap needs a lookup against the
consumer's own state. gakudan should own the **seam** and ship the universal
caps; pricing and cross-run/tenant policy belong to the consumer.

## Decision

### A `gakudan_budget` behaviour

```erlang
-callback check(usage(), context()) -> allow | {deny, Reason :: term()}.

usage()   :: #{tokens_in, tokens_out, total_tokens, llm_calls, turns}.
context() :: #{run_id, actor, opts}.
```

`check/2` is called **before each turn is dispatched**, with the run's
cumulative usage so far. `allow` proceeds; `{deny, Reason}` stops the run. A
single budget per run (not a chain), configured as a ref exactly like a
guardrail:

```erlang
budget => {gakudan_budget_limit, #{max_tokens => 100_000, max_llm_calls => 50}}
```

or via the `default_budget` app env. A consumer implements `check/2` against
its own price table or per-tenant counters; gakudan never interprets money.

### Built-in `gakudan_budget_limit`

The universal declarative caps, shipped so the common case needs no module:
`max_tokens`, `max_input_tokens`, `max_output_tokens`, `max_llm_calls`,
`max_turns`. The first cap met or exceeded denies with `{deny, {Cap, Limit}}`.
Absent caps are ignored.

### Enforcement: hard stop at the turn boundary

The run statem accumulates usage as each turn worker reports it, and calls the
budget before dispatching the next turn. On `{deny, {Mod, Reason}}` it:

1. appends a `system` entry recording the stop,
2. emits `[gakudan, budget, exceeded]` telemetry (`run_id`, `budget`, `reason`,
   plus the cumulative measurements),
3. stops the run with reason `{shutdown, {budget_exceeded, {Mod, Reason}}}` -
   a graceful stop (snapshot saved as `completed`), so `run_stopped` audit and
   `[gakudan, run, stop]` telemetry both carry the budget reason.

The stop is terminal. Raising the cap means starting a new run; there is no
resume (a budget pause-and-approve flow is a possible future addition, but
hard-stop is the honest default for a cost ceiling).

### Granularity and the overshoot bound

The check is at turn-dispatch boundaries, not before every individual LLM call
inside a turn's tool loop. So a budget can overshoot by at most one turn (one
fanout round), each turn bounded by `?MAX_TOOL_ITERATIONS` calls. Intra-turn
enforcement is a possible refinement; turn-boundary granularity keeps the
counter in one place (the statem) and is sufficient for a ceiling.

### Counter lifetime

The cumulative counter lives in the statem's in-memory state. It is **not**
persisted in the snapshot, so a supervised restart resets it to zero. This is
deliberate: persisting it would force exact, double-count-free accounting
against idempotent replays of cached LLM steps (ADR 0009), which is complex and
error-prone. The accepted consequence is that a run crashing and being resumed
can spend up to its budget again per incarnation. Restarts are rare; the bound
is acceptable for v1 and documented.

## Consequences

**Positive.**

- A hard cost ceiling - the concrete control a regulated operator needs,
  without gakudan shipping any pricing opinion.
- Pluggable and optional, like the checkpointer / guardrail / audit seams; zero
  cost when no budget is configured. Money and per-tenant caps are expressible
  by the consumer against the same behaviour.
- The `[gakudan, budget, exceeded]` event gives `gakudan_metrics` a clean
  signal to alert on (additive; no lockstep required).

**Negative.**

- Turn-boundary granularity allows a bounded overshoot (one turn).
- The in-memory counter resets on a supervised restart, so the cap is
  per-incarnation, not per-run-lifetime.
- The turn's internal `run/11` now returns `{ok, usage()}` instead of `ok` so
  the statem can accumulate. Internal only (the `run/10` shim still returns
  `ok`); noted for the record.
