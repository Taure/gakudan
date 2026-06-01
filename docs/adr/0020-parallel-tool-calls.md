# 20. Parallel tool calls within a turn

Date: 2026-06-01

## Status

Accepted.

## Context

A single LLM response can contain several `tool_use` blocks - the model
asks to call N tools before it continues. `gakudan_turn` ran them
sequentially via a list comprehension, so total tool latency was the sum of
the calls even when they were independent (a web fetch, a DB read, a
calculation that do not depend on each other). For tool-heavy turns this
dominates wall-clock time.

The blocks are independent within a turn - their results are all fed back
together as the next user message - so they can run concurrently. The
constraint is that the order of the returned `tool_result` blocks must match
the order of the `tool_use` blocks (providers correlate by id, but order
keeps transcripts deterministic and readable), and one tool crashing must
not take down the turn.

## Decision

- **Run a turn's tool calls concurrently on monitored workers.** A single
  call still runs inline (no spawn overhead). Two or more spawn one
  `spawn_monitor` worker each; the turn worker gathers `DOWN` messages and
  reassembles results by the original block index, so output order is
  independent of completion order.
- **Reuse the existing supervision shape.** The turn already runs in its own
  monitored worker spawned by the run statem (ADR 0007); tool workers are
  children of that worker and monitored the same way. No new supervisor is
  added - the turn worker is the join point and crashes are isolated to it.
- **A crashing tool becomes an error `tool_result` block**, not a turn
  failure: the worker's non-`{tool_result, _}` exit is converted to an
  `is_error` block carrying the crash reason, mirroring how an unknown tool
  or a `{error, _}` return is already surfaced.
- **Idempotency and caching are unchanged.** Each tool still computes its own
  deterministic step id and reads / writes the checkpointer independently
  (ADR 0009), so concurrent execution does not affect exactly-once replay.

## Consequences

**Positive.**

- Independent tool calls in one turn now overlap; turn latency drops toward
  the slowest call instead of their sum.
- Result ordering is deterministic regardless of which tool finishes first.
- Crash isolation is preserved: a faulty tool yields an error block, the
  turn continues, and the run is unaffected.

**Negative.**

- Tools in the same turn now genuinely run in parallel, so a tool with
  process-global side effects (shared ETS, a singleton gen_server) can see
  concurrent calls it previously never did. Tools must be safe under
  concurrency; this is normal for OTP code but is a behaviour change for any
  tool that implicitly relied on serialisation.
- Per-call spawn has a small cost; mitigated by running a lone call inline.
- Cancellation granularity is unchanged - a `gakudan_llm_cancel` reaches the
  turn worker, not individual tool workers, so in-flight tools run to
  completion before the turn unwinds.
