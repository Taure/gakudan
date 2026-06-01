# 17. Structured output and validation

Date: 2026-06-01

## Status

Accepted. Builds on [ADR 0016](0016-llm-request-options.md).

## Context

ADR 0016 added `response_format` to the request so an agent can ask a
backend for schema-constrained output. That gets a structured object out of
the model, but the run still needs to (a) recover the object from the
provider-specific response shape and (b) check it actually conforms before
downstream code depends on it. LLMs drift from a schema even when asked not
to, so unvalidated structured output is a latent crash.

The two backends surface a forced object differently. Anthropic / Vertex
have no first-class response-format, so the adapter forces a synthetic tool
(`structured_output`) and the object arrives as that `tool_use` block's
`input`. Gemini returns a JSON document in a `text` block. The run must
handle both without leaking provider detail into agents.

## Decision

- **Add a `gakudan_validator` behaviour**: `validate(Schema, Value) ->
  {ok, Value} | {error, [{Path, Detail}]}`, dispatched through a
  `{Module, Schema}` ref. Validation is pluggable so a host can validate
  against anything - a JSON-schema subset, an Erlang record shape, an
  external registry.
- **Ship `gakudan_validator_json`** as the default: a practical JSON-schema
  subset (`type`, `required`, `properties`, `items`, `enum`) with recursive
  object / array checks and JSON-path-style error locations. It is not full
  JSON-schema; it covers the constructs that constrain LLM output in
  practice. Schema keys and `type` values may be atoms or binaries.
- **Add `gakudan_structured`** to recover the object from either backend
  shape: prefer the `structured_output` tool_use input, else decode the
  first JSON text block. `{error, no_structured_output}` when neither is
  present.
- **Wire it into `gakudan_turn`**: when the request carries a
  `response_format`, the turn extracts and (if a `validator` ref is in the
  agent's `request_options`) validates the result. On success the typed
  value is written to the blackboard kv under `structured_output` as
  `#{agent_id => Id, value => Value}` and the JSON is appended to the
  transcript. On failure a `system` entry records the errors and a
  `[gakudan, validation, failed]` telemetry event fires; the run continues
  rather than crashing.
- **Config source**: `validator` rides in the agent's `request_options/0`
  map alongside `response_format`. `gakudan_turn` strips `validator` out
  before the request reaches the backend (it is a run-side concern).

## Consequences

**Positive.**

- Structured output is uniform to agents regardless of backend.
- Conformance is enforced before downstream code reads the value; the typed
  result is a first-class blackboard entry other agents / routers can read.
- The validator is swappable; the JSON default covers the common case with
  zero host code.

**Negative.**

- A validation failure is surfaced as a transcript entry, not a retry. A
  host that wants auto-repair must add a router / guardrail that reacts to
  the `system` entry or the telemetry event.
- The JSON validator is a subset; schemas using unsupported keywords (e.g.
  `pattern`, `minimum`) pass silently for those keywords. A host needing
  full coverage supplies its own validator module.
- Structured output occupies a tool slot and forces a tool call on the
  Anthropic path, which is visible in the transcript and precludes mixing
  free-form tool use with forced structured output in the same turn.
