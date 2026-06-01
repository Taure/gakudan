# 16. LLM request options

Date: 2026-06-01

## Status

Accepted.

## Context

The `gakudan_llm:request()` map locked in v0.1 carried only `model`,
`system`, `tools`, and `messages`. Every other generation knob a backend
supports - sampling temperature, an output-length cap, stop sequences,
forcing or suppressing tool use, asking for schema-constrained output -
was unreachable. Hosts that needed any of these had to write a bespoke
backend wrapper.

The fields are all backend-native concepts, so they belong on the request
the backend receives, not bolted onto the run config. They are also
per-agent: a planner may want low temperature and forced JSON output while
a coder runs at the default. The agent already owns `system_prompt/0`,
`tools/0`, and `model/0`; the new options sit naturally beside them.

## Decision

- **Widen `gakudan_llm:request()` with five optional fields**:
  `tool_choice`, `response_format`, `max_tokens`, `temperature`,
  `stop_sequences`. The change is a backward-compatible map extension; a
  request without any of them behaves exactly as before.
- **`tool_choice`** is a backend-neutral term -
  `auto | any | none | {tool, Name}` - each backend maps to its native
  shape (Anthropic `tool_choice` object, Gemini `functionCallingConfig`).
- **`response_format`** is a JSON schema (a map). It asks the backend for
  schema-constrained output. Anthropic has no first-class response-format,
  so the adapter coerces it via a single synthetic forced tool
  (`structured_output`) whose `input_schema` is the requested schema;
  Gemini maps it to `responseMimeType: application/json` + `responseSchema`.
  The validation half lives in [ADR 0017](0017-structured-output-validation.md).
- **Source of the options**: a new optional `c:gakudan_agent:request_options/0`
  callback returning a map. `gakudan_turn` merges it into the base request.
  Absent callback defaults to `#{}`. A request `max_tokens` takes
  precedence over a backend-opts `max_tokens`.
- **Threading**: Anthropic and Gemini map every field to provider-native
  request keys; Vertex inherits the mapping because it reuses
  `gakudan_llm_anthropic:build_body/2`.

## Consequences

**Positive.**

- All five knobs are reachable per-agent without a custom backend.
- The request shape stays a plain map; existing backends and tests are
  unaffected unless they opt in.
- A single behaviour-neutral `tool_choice` term keeps agents portable
  across backends.

**Negative.**

- `response_format` is not uniform across providers: on Anthropic it
  consumes a tool slot and forces a tool call, which is observable in the
  transcript. Documented in ADR 0017.
- Backends silently ignore fields they cannot express; there is no
  capability negotiation. A host pointing an agent at a backend that lacks
  a knob gets the backend default, not an error.
