# Changelog

All notable changes to gakudan are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and gakudan uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
