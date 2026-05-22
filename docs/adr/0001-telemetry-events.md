# 1. Telemetry event surface

Date: 2026-05-22

## Status

Accepted (v0.1).

## Context

`gakudan` needs production-grade observability without dragging in opinionated
metric, log, or trace infrastructure. The library will be embedded in apps
that already run their own stack (Prometheus, OpenTelemetry, StatsD, etc.).

The de facto BEAM standard for this is the `telemetry` library: a tiny,
zero-state, zero-dependency event bus. Cowboy, Phoenix, Ecto, and OTP itself
use it. Emitting `telemetry` events is the lowest-friction way to give every
gakudan user observability without forcing a choice.

Once the event names and metadata are emitted, downstream consumers
(dashboards, audit pipelines, evals) pin against them. Renaming events or
reshaping metadata after release is painful. The event surface is therefore
public API and must be locked before tagging v0.1.

## Decision

`gakudan` core depends on `telemetry` and emits the following events.

### Conventions

- Spans (operations with a start and a stop) follow `telemetry:span/3`:
  `[..., start]`, `[..., stop]`, and `[..., exception]` are emitted by the
  library. `duration` is in native time units (convert with
  `erlang.convert_time_unit/3`).
- Non-span events use `telemetry:execute/3` and carry their own measurements.
- All metadata maps include `run_id :: binary()` so consumers can correlate.

### Events

#### `[gakudan, run, start]`

Emitted once per run, after the run statem registers itself.

- Measurements: `#{system_time := integer()}` (native units)
- Metadata: `#{run_id, agents := [atom()], router := module(), llm_backend := module(), max_turns := pos_integer()}`

#### `[gakudan, run, stop]`

Emitted once per run, in the statem's `terminate/3`.

- Measurements: `#{duration := non_neg_integer(), turns := non_neg_integer()}`
- Metadata: `#{run_id, reason := term()}`

#### `[gakudan, turn, start]`

Emitted when a turn worker is dispatched.

- Measurements: `#{system_time := integer()}`
- Metadata: `#{run_id, agent_id := atom(), turn := pos_integer()}`

#### `[gakudan, turn, stop]`

Emitted when the turn worker reports back (complete or failed).

- Measurements: `#{duration := non_neg_integer()}`
- Metadata: `#{run_id, agent_id := atom(), turn := pos_integer(), outcome := ok | failed, reason => term()}`

#### `[gakudan, llm, request, start | stop | exception]`

A `telemetry:span/3` around `LMod:complete/2`. Emitted from the turn worker.

- Span metadata: `#{run_id, agent_id := atom(), backend := module(), model := binary()}`
- Stop measurements (added to `duration`): `#{tokens_in := non_neg_integer(), tokens_out := non_neg_integer()}`
- Stop metadata (added): `#{outcome := ok | error, reason => term()}`

Backends are expected to return `#{usage => #{input_tokens, output_tokens}}`
in the response so the wrapper can fill in token counts. Backends that do
not surface usage report zeros.

#### `[gakudan, tool, run, start | stop | exception]`

A `telemetry:span/3` around `ToolMod:run/1`. Emitted from the turn worker.

- Span metadata: `#{run_id, agent_id := atom(), tool := binary()}`
- Stop metadata (added): `#{outcome := ok | error, reason => term()}`

#### `[gakudan, router, decide, start | stop | exception]`

A `telemetry:span/3` around `RouterMod:next/2`. Emitted from the run statem.

- Span metadata: `#{run_id, router := module()}`
- Stop metadata (added): `#{decision := {next, atom()} | done}`

### Stability

The event names, the keys present in measurements, and the keys present in
metadata are stable from v0.1 onward and follow semver: breaking changes
require a major-version bump. Adding new measurement keys, metadata keys,
or new events is a minor bump.

## Consequences

**Positive.**

- Users get production-grade observability via their existing stack without
  any gakudan-specific glue.
- A companion `gakudan_metrics` library can subscribe to these events,
  expose Prometheus metrics, and ship a Grafana dashboard, without changing
  core.
- The eval harness can replay transcripts against the stub and assert on
  the same events (token counts, turn outcomes, tool calls) that production
  observes.
- Cost telemetry is solved on day one: `tokens_in / tokens_out` per
  `llm.request` are first-class.

**Negative.**

- One mandatory dependency: `telemetry`. It is small, dep-free, and
  ubiquitous in the BEAM ecosystem, so the cost is low.
- Event names become part of the public API. Future refactors must preserve
  them or follow semver.
