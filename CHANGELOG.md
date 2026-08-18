# Changelog

All notable changes to gakudan are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and gakudan uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **OAuth 2.1 for the MCP client.** `gakudan_mcp_client` auth gains
  `{oauth2, #{token_url, client_id, client_secret, scope}}` - the OAuth 2.1
  client-credentials grant for OAuth-gated MCP servers. The access token is
  fetched from `token_url`, cached with its expiry, refreshed when it lapses,
  and a `401` triggers a one-shot refetch-and-retry. The bearer header path is
  unchanged. Authorization-code/PKCE is out of scope for a headless client.
  See [ADR 0015](docs/adr/0015-mcp-oauth.md).

- **Streaming cancellation + load-shedding.** New `gakudan:cancel/1` stops a
  run's in-flight generation: the backend `httpc` request is aborted
  (`gakudan_llm_cancel` reaches the worker's `stream_loop`), subscribers get a
  `{cancelled, _}` event, and the run returns to `idle` with a `system` entry
  and `[gakudan, run, cancelled]` telemetry. `gakudan_stream` sheds load per
  subscriber: events for a subscriber whose mailbox exceeds `stream_max_queue`
  (app env, default 10000) are dropped, with a `{dropped, N}` marker folded
  into its next delivery. See
  [ADR 0014](docs/adr/0014-streaming-cancellation-backpressure.md).

- **Cost budgets.** New `gakudan_budget` behaviour: a budget is checked
  before each turn is dispatched and stops the run before it spends past a
  ceiling. Built-in `gakudan_budget_limit` covers the universal caps
  (`max_tokens`, `max_input_tokens`, `max_output_tokens`, `max_llm_calls`,
  `max_turns`); money and per-tenant policy are expressible by implementing
  `check/2`. On a breach the run stops gracefully with reason
  `{budget_exceeded, {Mod, Reason}}`, records a `system` entry, and emits a
  `[gakudan, budget, exceeded]` telemetry event. Configured per run
  (`budget => Ref`) or via the `default_budget` app env; a no-op when unset.
  The cumulative counter is in-memory and resets on a supervised restart. See
  [ADR 0013](docs/adr/0013-cost-budgets.md).

- **Audit logging.** New `gakudan_audit` behaviour: a synchronous,
  recorded-before-the-action sink for must-not-lose events, distinct from
  best-effort telemetry. Covers `run_started`, `run_resumed`,
  `run_interrupted`, `run_stopped`, and every guardrail decision
  (`guardrail_allow` / `guardrail_transform` / `guardrail_block`). An
  `on_error` policy of `log` or `fail_closed` decides whether a sink write
  failure halts the action. Configured per run (`audit => {Mod, Opts}`) or via
  the `default_audit` app env; a no-op when unset. `gakudan_audit_kura` is the
  default sink (append-only rows, `actor`/`tenant` columns, per-run SHA-256
  hash chain with serialized `FOR UPDATE` writes + chain-walking `verify/2`).
  See [ADR 0012](docs/adr/0012-audit-logging.md).
- **Actor attribution.** `run_config` gains an optional opaque `actor` map
  (convention `#{id, tenant}`), threaded verbatim into audit events and
  run-lifecycle telemetry metadata.

- **MCP client.** New `gakudan_mcp_client` gen_server speaks the
  Streamable HTTP transport of the Model Context Protocol. One process
  per remote MCP endpoint; performs the `initialize` handshake on
  start, caches the server's tool list, exposes `list_tools/1`,
  `get_tool/2`, `call_tool/3`. Auth supports bearer tokens.
  `as_tools/1` returns `gakudan_tool:ref()` values ready to splice
  into an agent's `tools/0`. See
  [ADR 0006](docs/adr/0006-mcp-client.md).
- **`gakudan_mcp_tool` adapter.** Single module that wraps any
  MCP-discovered tool. Agents reference MCP tools as
  `{gakudan_mcp_tool, #{client => Name, name => ToolName}}`.
- **`gakudan_tool` extension.** New optional callbacks `spec/1` and
  `run/2` let tools carry per-instance opts. Agents can now mix
  module-only tools (`my_tool`) and parameterised tools
  (`{gakudan_mcp_tool, Opts}`) in the same `tools/0` list. The turn
  worker resolves both forms uniformly via `gakudan_tool:resolve/1`.
  Backwards-compatible: existing module-only tools work unchanged.

### Changed

- **LLM credentials no longer reach the checkpoint, supervisor child specs,
  crash reports or `sys:get_status`.** The run's real `llm` spec is held in
  `gakudan_registry` for the life of the run; the config that travels into
  `gakudan_runs_sup`, `gakudan_run_sup`'s child spec and every snapshot is a
  redacted copy. `gakudan_run_statem` gained `format_status/1` so the state
  data is redacted too. Previously a supervisor `child_terminated` or
  `start_error` report - triggered by any crash, or a bad checkpointer spec -
  printed the whole config including `api_key` at ERROR level, and
  `sys:get_status/1` returned it to any process on the node.
- **A run with no usable LLM credential now fails instead of idling forever.**
  `{error, no_api_key}` used to be appended to the blackboard as transcript
  text, leaving the run `idle` - which `is_active/1` counts as live, so
  `gakudan_runs_resumer` re-resumed it on every node boot, and `await/2`
  returned `{ok, Entries}` as if it had succeeded. The run now tears down and
  snapshots as `failed`.
- **LLM credentials are no longer written to the checkpoint.**
  `gakudan_checkpointer:save_snapshot/2` now strips `api_key`,
  `access_token` and `token_fun` from the persisted run config, recursively
  through composed `backend`/`backends` specs. Previously an inline key was
  stored in plain text in `gakudan_runs.data` and every backup of it.
  **Breaking for unattended resume if you pass a key inline and do not set
  the matching environment variable.** The backends fall back to
  `ANTHROPIC_API_KEY`, `GEMINI_API_KEY` and `GOOGLE_VERTEX_TOKEN`; a run
  resumed by `gakudan_runs_resumer` with neither will now fail with
  `{error, no_api_key}` where it previously succeeded. Set the env var on
  any node that resumes runs. See ADR 0003.
- `gakudan_llm_retry` retries HTTP 429, on a tighter budget than 5xx -
  `max_rate_limit_attempts`, default 2 - because retrying is offered load
  into a limiter that just said stop, and the multipliers compound across
  router iterations, fanout agents and fallback backends. Backoff is now
  jittered so co-failing fanout workers do not retry in lockstep.
  `Retry-After` is not honoured: the `{http_error, Code, Body}` shape carries
  no headers.
- `gakudan_llm_retry`'s backoff is interruptible. A `gakudan_llm_cancel`
  arriving mid-backoff previously sat unread until the next attempt had
  already been issued; it now ends the call promptly, and on the streaming
  path emits the `{cancelled, #{}}` event to the subscriber.

- `gakudan_agent:tool_spec()` widened from `module()` to
  `gakudan_tool:ref()` (which is `module() | {module(), map()}`).

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
