# Changelog

All notable changes to gakudan are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and gakudan uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Gemini streaming backend.** `gakudan_llm_gemini:stream_call/3` hits
  `streamGenerateContent?alt=sse`, decodes Gemini's candidate-snapshot
  SSE chunks, and emits `gakudan_llm:stream_event()` to the subscriber.
  Per-chunk `text` parts accumulate into a single text block per
  contiguous run; `functionCall` parts flush the current text and
  emit `tool_use_start` + `tool_use_input_delta`. `finishReason` is
  mapped to `stop_reason` on the canonical response (`STOP -> end_turn`,
  `TOOL_CALL -> tool_use`, `MAX_TOKENS -> max_tokens`). Same public
  testable seam as Anthropic (`fresh_stream_acc/0`,
  `feed_stream_chunk/4`, `finalise/1`, `apply_gemini_event/2`).
- **`gakudan_sse:parse/2`** as a shared byte-level SSE primitive used
  by both backends. `gakudan_llm_anthropic:parse_sse/2` now delegates;
  the public surface is unchanged.
- **`gakudan_llm_anthropic:feed_stream_chunk/4`** (plus `fresh_stream_acc/0`
  and `finalise/1`) exposed as the public testable seam for the streaming
  pipeline. Three new CT cases drive a canned SSE byte sequence through
  the whole flow and assert both the subscriber event sequence and the
  finalised `gakudan_llm:response()`, including a chunk-boundary split
  inside an event.
- **Anthropic streaming backend.** `gakudan_llm_anthropic:stream_call/3`
  hits `/v1/messages` with `stream: true`, parses the SSE wire format,
  and emits `gakudan_llm:stream_event()` to the subscriber as tokens
  arrive. Tracks per-index `text` and `tool_use` content blocks,
  accumulates `usage` (including `cache_read_input_tokens` /
  `cache_creation_input_tokens`), and finalises the canonical response
  on `message_stop`. SSE parser and event-mapping helpers are exposed
  (`parse_sse/2`, `apply_anthropic_event/2`) for downstream consumers
  and unit-testing.
- **Streaming LLM responses.** Optional `gakudan_llm:stream_call/3`
  callback lets backends push token-by-token deltas to a per-call
  subscriber pid. Backends that do not implement it transparently fall
  back to `complete/2` wrapped in a single `text_delta` event, so the
  API surface stays uniform.
- **Per-run stream pubsub** (`gakudan_stream`) runs alongside the
  blackboard in each run's supervision tree. Subscribers receive
  `{gakudan_stream, RunId, Event}` messages.
- **Public API:** `gakudan:subscribe_stream/1` and
  `gakudan:unsubscribe_stream/2`. Slow subscribers fall behind on their
  own mailbox; monitor cleanup removes them on crash. Cancellation and
  backpressure deferred to v0.4.
- **`gakudan_llm_stub` streaming variant.** Scripted responses now
  accept a `{stream_chunks, [binary()]}` form that emits one
  `text_delta` per chunk, for multi-event test coverage.
- **Streaming telemetry**: `[gakudan, llm, stream, start | token |
  complete]` events. Extends ADR 0001. Token events are high-volume;
  consumers should sample or batch. See
  [ADR 0005](docs/adr/0005-streaming.md).
- `gakudan_llm_anthropic` now marks the system prompt and tool definitions
  with `cache_control: {type: ephemeral}` so Anthropic caches them across
  calls within the 5-minute window. For multi-turn agent runs, this drops
  the system + tools portion of every call after the first to ~10% of the
  uncached input-token cost. The hint is silently ignored below
  model-specific minimum thresholds (1024 tokens for Sonnet, 2048 for
  Haiku), so it is safe for short prompts.
- `gakudan_llm:usage()` type gains optional `cache_creation_input_tokens`
  and `cache_read_input_tokens` fields. The Anthropic backend now
  forwards these when present in the API response.

## [0.1.1] - 2026-05-23

### Added

- `gakudan_llm_gemini` - Google Gemini `generateContent` backend. Reads
  `GEMINI_API_KEY` from env (or `Opts`), translates the gakudan/Anthropic
  request/response shape bidirectionally (system prompt, messages,
  tools, tool_use / tool_result, usage). Synthesises tool-call ids for
  Gemini `functionCall` parts (Gemini does not issue them); recovers
  tool names for `functionResponse` parts from the prior `tool_use`
  blocks in the same conversation. Override `base_url` or `api_version`
  via `Opts` for proxy / beta-API use.
- `examples/debate` - three-agent decision-pressure-test example: proponent
  argues FOR, opponent argues AGAINST, synthesiser summarises and
  recommends. Includes a custom `debate_router` (cycles debaters for N
  rounds, then forces one synthesiser turn) and a `debate:eval_stub/0`
  case that drives `gakudan_eval` end-to-end.

### Changed

- CI pins `Taure/erlang-ci` to `@v2.1.1` (explicit) instead of `@v2.1.0`.
  Picks up the upstream fix for the dangling audit composite ref that
  caused the `Audit` job to fail on every PR since v0.1.0.

## [0.1.0] - 2026-05-22

### Added

- Initial public release.
- **Five pluggable primitives:** Run, Agent, Router, Blackboard, Tool, plus
  an LLM backend behaviour. One supervision tree per run.
- **Three built-in routers:** `gakudan_router_round_robin`,
  `gakudan_router_handoff` (with `@<agent>` tokens), and
  `gakudan_router_manager` (manager picks next worker).
- **Two LLM backends:** `gakudan_llm_anthropic` (non-streaming Messages API)
  and `gakudan_llm_stub` (deterministic, for tests and offline demos).
- **`telemetry` event surface** at every run / turn / LLM request / tool
  call / router decision boundary. `tokens_in` / `tokens_out` are
  first-class on `[gakudan, llm, request, stop]`, so per-team cost
  telemetry is solved on day one. Events and metadata schemas are public
  API from v0.1 onward (see
  [ADR 0001](docs/adr/0001-telemetry-events.md)).
- **`gakudan_eval` harness** for deterministic agent collaboration evals.
  Replays scripted LLM responses against the stub, collects the transcript
  and telemetry stream, runs declarative expectations, and returns a
  structured pass/fail report. Matcher vocabulary defined in
  [ADR 0002](docs/adr/0002-eval-harness.md).
- **Companion library** [`gakudan_metrics`](https://github.com/Taure/gakudan_metrics)
  exports the telemetry events as Prometheus metrics and ships a starter
  Grafana dashboard.
- **Companion library** `gakudan_liveboard` (planned, Arizona) for the
  human-observability view.
- Offline `planner_coder` example under `examples/`.

### Known limitations

- Single-node only. No multi-node distribution.
- No streaming responses (planned for v0.2).
- `gakudan_run_sup` is `temporary`; runs in flight do not survive a BEAM
  restart. Plug your own persistence (e.g. via kura) if you need it.
- Tools dispatch synchronously in-process; wrap behind shigoto or similar
  for long-running tools.

[Unreleased]: https://github.com/Taure/gakudan/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/Taure/gakudan/releases/tag/v0.1.1
[0.1.0]: https://github.com/Taure/gakudan/releases/tag/v0.1.0
