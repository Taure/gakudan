# 8. OpenTelemetry span export

Date: 2026-05-26

## Status

Proposed.

## Context

ADR 0001 made `telemetry` events the stable observability surface, and
`gakudan_metrics` turns them into Prometheus counters and histograms.
That answers "how many runs, how much latency, how many tokens, how
much error" - aggregate questions, across a fleet.

It does not answer "what happened in *this* run." There is no way to see
a single run as a tree: the run, its turns, the LLM call and tool calls
inside each turn, the router decisions between them, with timings and
parent/child relationships. For debugging a misbehaving multi-agent run,
and for the audit trail a regulated operator needs, that trace view is
the thing you actually reach for.

By 2026 the entire field has standardised on **OpenTelemetry** as the
trace wire format: Strands, Pydantic AI, and Microsoft Agent Framework
emit OTel spans natively; LangSmith and Logfire sit on top of the same
data model. An OTel-native gakudan plugs into Jaeger, Tempo, Honeycomb,
Grafana, Datadog, and any OTLP collector with zero bespoke glue. We
already emit `telemetry:span/3`-shaped events at every level
(`[gakudan, run | turn | llm, request | tool, run | router, decide]`);
the data is there, it just is not shaped as a span tree.

Two constraints:

1. **Core must not grow an OTel dependency.** Same rule as
   `gakudan_metrics`: tracing is an opt-in companion library, not a core
   dep. The `telemetry` events stay the only contract.
2. **Turns run in separate processes.** A turn worker is a `spawn_monitor`
   child of the run statem, and the LLM/tool spans fire inside that
   worker. OTel context does not cross a process boundary by itself, so
   the span tree cannot be stitched purely from the implicit
   `otel_ctx`; it must be reconstructed from the run/turn/agent/request
   identifiers the events already carry.

## Decision

Ship a separate `gakudan_otel` companion library (sibling to
`gakudan_metrics`), depending on `opentelemetry_api` (and, for a batteries-
included path, `opentelemetry` + an OTLP exporter the operator wires
up). Core gakudan needs one small, additive change (below); everything
else lives in the companion.

### Span tree

Reconstruct this hierarchy from the existing events:

```
run            (root span; trace_id derived from run_id)
├── router.decide        (child of run)
├── turn                 (child of run)
│   ├── llm.request      (child of turn)
│   │   └── llm.stream   (events annotate the llm.request span)
│   └── tool.run         (child of turn, one per tool call)
├── router.decide
└── turn ...
```

A fanout (ADR 0007) naturally shows as sibling `turn` spans under the
same `run`, with overlapping wall-clock intervals - the trace view makes
parallelism visible at a glance.

### Context stitching

`gakudan_otel` attaches handlers to the start/stop of each telemetry
span event and maintains a small ETS table mapping correlation keys to
live OTel span contexts:

- `{run_id}` -> root span ctx
- `{run_id, turn}` -> turn span ctx

When a child event arrives, the handler looks up its parent ctx by key
and starts the OTel span with that explicit parent, rather than relying
on process-dictionary propagation. `llm.request` and `tool.run` spans
are children of the turn span, looked up by `{run_id, turn}`; they need
no registry entry of their own (nothing nests under them in v1).
`trace_id` is derived deterministically from `run_id` so a resumed run
(ADR 0004) continues the same trace across a BEAM restart.

### The one core change: `turn` on the llm/tool spans

The turn span is keyed by `{run_id, turn}`, so the `llm.request` and
`tool.run` span events must carry `turn` in their metadata to find their
parent. The `run` and `turn` events already do; the `llm.request` and
`tool.run` spans, as of v0.4, carry `run_id` + `agent_id` but **not**
`turn`. This ADR therefore adds `turn` to those two spans' metadata - a
single map key, backwards compatible (ADR 0001 consumers ignore unknown
keys), and the only change required in core.

**Why not key the turn span by `{run_id, agent_id}` and skip the core
change?** Because ADR 0007 lets one fanout run the same agent more than
once concurrently (e.g. `{fanout, [critic, critic, critic]}` to sample a
critic for variance). Those workers share an `agent_id` but get distinct
turn numbers, so `{run_id, agent_id}` would collide and nest llm/tool
spans under the wrong turn. Turn numbers are unique within a run by
construction, so `{run_id, turn}` is the only correct key - which is
what makes the small metadata addition worth it.

### What lands on each span

- `run`: `gakudan.run_id`, `gakudan.router`, `gakudan.llm_backend`,
  `gakudan.max_turns`; status set from the stop reason.
- `turn`: `gakudan.agent_id`, `gakudan.turn`, outcome.
- `llm.request`: `gakudan.backend`, `gakudan.model`, `tokens_in`,
  `tokens_out`, cache token counts when present; error -> span status
  error with the reason.
- `tool.run`: `gakudan.tool`, outcome; tool errors recorded as span
  events.
- `router.decide`: `gakudan.router`, the decision (`next` / `fanout` /
  `done`).

### Opt-in

`gakudan_otel:setup/0` attaches the handlers; nothing happens until the
host application calls it and configures an exporter via the standard
`opentelemetry` application env. Sampling, batching, and export are the
OTel SDK's job, not ours - including dropping the high-cardinality
`run_id`/`turn`/`request_id` dimensions that `gakudan_metrics`
deliberately keeps out of Prometheus labels but that are exactly what a
trace wants.

## Consequences

**Positive.**

- A full per-run trace in any OTLP backend, including parallel fanouts
  rendered as overlapping sibling spans.
- Drops gakudan into the same observability pane as the rest of an
  org's services; the audit trail (every LLM call, every tool call,
  with timing and token cost) becomes a first-class artifact for
  regulated use.
- Core stays dependency-clean; `telemetry` events remain the only
  contract. `gakudan_metrics` and `gakudan_otel` are parallel consumers
  of the same stream.

**Negative.**

- Cross-process context is stitched manually via the correlation ETS
  table rather than native `otel_ctx` propagation. The table must be
  cleaned on `run`/`turn`/`request` stop to avoid leaks; a crashed turn
  that never emits a stop needs a sweep keyed off the run-stop event.
- Trace volume is per-LLM-call; high-throughput deployments must rely on
  OTel SDK sampling. Documented as the operator's tuning knob.
- A second companion library to version alongside core, like
  `gakudan_metrics`.
