# Architecture Decision Records

The decision log for gakudan. Each ADR captures the *why* behind a behaviour,
backend, or contract - the context an agent or contributor needs before
changing it.

## When to write one

Write a new ADR for any new behaviour, backend, or change to an existing
contract (a behaviour callback, a public API shape, a persisted format). Small
fixes and refactors that preserve contracts do not need one.

Use the [Nygard format](https://github.com/joelparkerhenderson/architecture-decision-record):
**Context** (the forces), **Decision** (what we chose), **Consequences** (the
trade-offs). Number sequentially; never rewrite a merged ADR - supersede it
with a new one.

## Index

| ADR | Title |
| --- | --- |
| [0001](0001-telemetry-events.md) | Telemetry events |
| [0002](0002-eval-harness.md) | Eval harness |
| [0003](0003-checkpointer-behaviour.md) | Checkpointer behaviour |
| [0004](0004-resume-interrupt-idempotency.md) | Resume / interrupt idempotency |
| [0005](0005-streaming.md) | Streaming |
| [0006](0006-mcp-client.md) | MCP client |
| [0007](0007-parallel-agent-execution.md) | Parallel agent execution |
| [0008](0008-opentelemetry-spans.md) | OpenTelemetry spans |
| [0009](0009-tool-idempotency-supervised-resume.md) | Tool idempotency + supervised resume |
| [0010](0010-guardrails.md) | Guardrails |
| [0011](0011-cloud-provider-backends.md) | Cloud provider backends |
| [0012](0012-audit-logging.md) | Audit logging |
| [0013](0013-cost-budgets.md) | Cost budgets |
| [0014](0014-streaming-cancellation-backpressure.md) | Streaming cancellation + backpressure |
| [0015](0015-mcp-oauth.md) | MCP OAuth 2.1 |
