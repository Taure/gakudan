# 10. Guardrails

Date: 2026-05-26

## Status

Accepted (v0.5).

## Context

For regulated and enterprise use, an operator needs to enforce policy on
what crosses the LLM boundary: redact PII before it leaves the process,
block prompt-injection or unsafe content, reject responses that violate
a content policy. By 2026 this is first-class in the field (OpenAI Agents
SDK input/output guardrails, CrewAI guardrails).

gakudan has no such hook today. The design tension is the usual one: a
guardrail layer must be powerful enough to block and redact, without
gakudan shipping opinionated PII regexes or content classifiers - that
would be "framework," not "primitives." gakudan should own the **seam**;
the policy belongs to the consumer.

## Decision

### A `gakudan_guardrail` behaviour

```erlang
-callback check(stage(), Payload :: term(), context()) ->
    allow | {block, Reason :: term()} | {transform, NewPayload :: term()}.

stage()   :: input | output.
context() :: #{run_id, agent_id, turn, stage, opts}.
```

- `input` payload is the message list about to be sent to the LLM.
- `output` payload is the final agent text (the `end_turn` result).
- `allow` passes the payload through unchanged.
- `{block, Reason}` rejects it.
- `{transform, NewPayload}` rewrites it (redaction) and continues.

### Configured per run as an ordered chain

```erlang
guardrails => [my_pii_redactor, {my_content_policy, #{max_severity => high}}]
```

A guardrail ref is `module() | {module(), Opts :: map()}` (opts arrive in
`context.opts`). The chain runs in order: the first `{block, _}` stops it
and wins; a `{transform, _}` result feeds the next guardrail. An empty or
absent list is a no-op.

### Where they run

In the turn worker, around each LLM call:

- **input** guardrails run before every LLM request in the tool loop
  (tool results can introduce new content, so each request is checked).
- **output** guardrails run on the final `end_turn` text before it is
  appended to the blackboard.

On a `{block, _}`, the turn appends a `system` entry recording the block
(`input blocked by <mod>: <reason>` / `output blocked ...`) and produces
**no agent output**. A block is a policy outcome, not a crash - the run
continues, and the router sees the block in the transcript. A
`[gakudan, guardrail, block]` telemetry event fires for the audit trail.

### Interaction with idempotency (ADR 0004/0009)

Input guardrails run before the (possibly cached) LLM step. On replay the
cached response is returned, already produced from guard-checked input.
Output guardrails run on the response whether cached or fresh, so a
policy change is re-applied on replay. Guardrails are evaluated with the
*current* policy, which is the desired behaviour for compliance.

### Non-goals

- **No built-in guardrails.** gakudan ships the behaviour and the chain
  runner, not a single filter. PII detection, content classification,
  and injection heuristics are the consumer's modules.
- **Tool-call approval is not a guardrail.** "Require a human before this
  tool runs" is the existing interrupt/resume (HITL) mechanism, not this.
- **Guardrails are synchronous, in the turn-worker process.** A slow
  guardrail blocks that turn (only that turn - other fanout branches run
  in their own processes).

## Consequences

**Positive.**

- A real enforcement point for PII / safety / compliance, which is a
  likely adoption gate for regulated operators - without warping the
  library toward any one policy.
- The `[gakudan, guardrail, block]` event plus the `system` block entry
  give an audit trail of every policy action.
- Pluggable and optional, exactly like the checkpointer and llm backend;
  zero cost when no guardrails are configured.

**Negative.**

- Per-iteration input checks add a call per LLM round; the cost is the
  consumer's guardrail implementation, not the library's.
- Block semantics (turn yields a `system` entry, no agent text) are a
  contract routers must account for when aggregating.
- A buggy or slow guardrail degrades the turn it runs in. Documented;
  guardrails should be fast and total.
