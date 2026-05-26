# 14. Streaming cancellation and load-shedding

Date: 2026-05-26

## Status

Accepted (v0.5).

## Context

ADR 0005 shipped token streaming and deferred two robustness items "to v0.4 if
asked for":

1. **Cancellation.** A v0.3 stream cannot be stopped mid-flight - there is no
   "stop generating, I have enough" hook. A user who navigates away, a
   supervisor that wants to reclaim a runaway turn, or an operator cutting a
   bad generation all have to wait for the model to finish.
2. **Backpressure.** `gakudan_stream` fans events out with a fire-and-forget
   cast; a slow subscriber's mailbox grows unbounded and there is no flow
   control.

Cost budgets (ADR 0013) blunted the worst runaway-spend case, but neither cap
nor budget can stop an *individual* in-flight generation, and neither protects
the pubsub from a slow consumer. This ADR closes both.

## Decision

### Cancellation

A new `gakudan:cancel/1` stops a run's in-flight generation:

```erlang
ok = gakudan:cancel(RunId).
```

**Mechanism.** Each LLM stream runs in a turn-worker process, blocked in the
backend's `stream_loop` receiving `{http, {ReqId, stream, _}}` chunks from an
async `httpc` request. The run statem knows the worker pids (it spawned and
monitors them). `cancel/1` makes the statem send each in-flight worker the bare
atom `gakudan_llm_cancel`. A worker runs exactly one stream at a time, so a
Ref-less signal is unambiguous (the per-call `Ref` lives only inside the
worker, so the statem could not address it anyway).

Each backend's `stream_loop` gains one clause:

```erlang
gakudan_llm_cancel ->
    _ = httpc:cancel_request(ReqId),
    Subscriber ! {gakudan_llm_stream, Ref, {cancelled, #{}}},
    {error, cancelled};
```

`httpc:cancel_request/1` tears down the connection (the same call the existing
timeout clause already makes), so there is no leaked request. The new
`{cancelled, map()}` stream event lets subscribers see the stop. The backend
returns `{error, cancelled}`, which the turn distinguishes from a real error
and returns up as `{cancelled, usage()}`; the worker reports `turn_cancelled`
and the statem takes the run to `idle`, emitting `[gakudan, run, cancelled]`
and a `system` transcript entry. Cancellation is a clean stop, not a crash.

**Granularity.** The signal is consumed at the LLM-stream receive. If a worker
is mid-tool-call when `cancel/1` arrives, the signal waits in its mailbox and
takes effect at the next LLM stream (or is harmlessly discarded if the turn
finishes first). Cancelling the long part - generation - is the goal; finer
mid-tool cancellation is out of scope.

### Load-shedding (the honest form of backpressure)

A token stream fans out from a producer that cannot be slowed (the model emits
at its own rate), so true producer backpressure does not apply. The real risk
is one slow subscriber's mailbox growing without bound. `gakudan_stream`
therefore **sheds load per subscriber**: before delivering, it checks the
subscriber's `message_queue_len`; if it exceeds a high-water mark
(`stream_max_queue`, default 10000, configurable via app env), the event is
dropped for that subscriber and a `{dropped, N}` marker is coalesced into its
next delivered event. Other subscribers are unaffected, and the pubsub never
blocks on a slow consumer.

This is load-shedding, not classical backpressure, and the ADR says so: for a
fan-out token stream it is the correct shape. A consumer that needs every token
should drain promptly or subscribe a dedicated buffering process.

## Consequences

**Positive.**

- A real stop-generation control, leak-free (reuses `httpc:cancel_request`),
  across all built-in backends with one symmetric clause each.
- The pubsub is protected from a slow subscriber without affecting others or
  blocking the producer.
- Cancellation is a graceful `idle` transition, observable via telemetry and
  the transcript.

**Negative.**

- The cancel clause is duplicated across the three `httpc`-based backends
  (anthropic, gemini, vertex). They already duplicate the whole `stream_loop`;
  factoring that out is a separate refactor.
- Cancellation granularity is the LLM-stream boundary, not mid-tool.
- Load-shedding drops events for a slow subscriber rather than guaranteeing
  delivery; the `{dropped, N}` marker makes the loss visible, but it is loss.
- The `cancelling` flag is in-memory, not snapshotted, so cancel is not
  crash-durable: if the run process crashes in the sub-millisecond window
  between acknowledging `cancel/1` and the fanout draining, a supervised resume
  re-runs the in-flight fanout rather than staying cancelled. Cancel is a
  best-effort live control, not a persisted decision; re-issue it after a
  crash if needed.
- The turn's internal `run/11` gains a `{cancelled, usage()}` return alongside
  `{ok, usage()}`; internal only (the `run/10` shim still collapses to `ok`).
