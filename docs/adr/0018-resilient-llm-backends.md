# 18. Resilient LLM backends (fallback + retry)

Date: 2026-06-01

## Status

Accepted.

## Context

Provider outages, rate limits, and transient 5xx / timeout errors are a
fact of running against a hosted LLM. Two recovery strategies are common:
**fall through** to a different provider, and **retry** the same provider
with backoff. The run loop already treats `{error, _}` from a backend as a
turn failure, so without help one transient blip kills a turn.

The library's pillar is "primitives, not a framework" and "no single-
consumer warping". Baking retry / fallback policy into `gakudan_turn` or
the run statem would warp the core for one cross-cutting concern and make
the policy non-swappable. Both strategies are, however, expressible purely
in terms of the existing `gakudan_llm` behaviour: a backend that delegates
to other backends.

## Decision

- **Resilience is composable backends, not core changes.** Two new modules
  implement `gakudan_llm` and wrap inner `{Module, Opts}` specs. The run's
  `llm` spec points at a wrapper; core is untouched.
- **`gakudan_llm_fallback`** takes `backends => [llm_spec()]` and tries each
  in order, returning the first `{ok, _}`. On `{error, _}` it falls through
  to the next; if all fail it returns the last error. A `{error, cancelled}`
  is terminal and never falls through (a user cancel must not fan out across
  providers).
- **`gakudan_llm_retry`** takes a single `backend => llm_spec()` plus
  `max_attempts` / `base_delay` / `max_delay`, and retries only transient
  errors: HTTP 5xx, `timeout`, and connection-level failures. Client errors
  (4xx), `no_api_key`, and `cancelled` return immediately. Backoff is
  exponential, capped: `min(max_delay, base_delay * 2^(attempt-1))`.
- **They compose either way.** Wrap each fallback entry in a retry to
  retry-then-fall-through, or wrap a fallback in a retry to retry the whole
  chain. Both wrappers forward `stream_request_id` so streaming dispatch and
  cancellation keep working through the layers.
- **Transient classification is exported** (`gakudan_llm_retry:transient/1`)
  so hosts and tests can reason about it.

## Consequences

**Positive.**

- Fallback and retry are opt-in, swappable, and testable in isolation -
  no HTTP needed, just inner backends that return fixed results.
- Core stays policy-free; the run loop still sees a single `gakudan_llm`
  backend and is unaware resilience is happening.
- Arbitrary composition (retry-of-fallback, fallback-of-retry) falls out of
  the behaviour with no special cases.

**Negative.**

- Retry uses `timer:sleep/1` inside the calling turn worker, so a turn can
  block for up to the summed backoff. That is acceptable because each turn
  already runs in its own worker process (ADR 0007) and remains cancellable;
  a future async variant could be added if needed.
- Streaming retry re-runs the whole stream on failure; partial deltas
  already emitted to a subscriber are not rewound. Retrying a stream that
  failed mid-flight can therefore double-emit early tokens. Hosts that
  cannot tolerate that should retry only the non-streaming path or dedupe
  downstream.
- Fallback across providers can mean a turn silently switches model
  families; the warning log records each fall-through so this is observable.
