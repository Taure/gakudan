# 12. Audit logging

Date: 2026-05-26

## Status

Accepted (v0.5).

## Context

Guardrails (ADR 0010) give an operator an enforcement point at the LLM
boundary, and the telemetry surface (ADR 0001) gives observability. Neither
is an audit trail. For regulated use - the load-bearing requirement for the
9-team rollout this library backs - an operator must be able to answer, after
the fact and with a durable record: *who* started a run, *what* the agents and
tools did, *which* policy decisions fired, and *when* a human interrupted or
resumed it.

Telemetry is the wrong tool for that record. `telemetry:execute/3` is
fire-and-forget; a handler may be detached on the first crash, and a slow
handler is silently dropped. The blackboard is the run transcript, but it is
per-run and snapshot-shaped, not a queryable cross-run ledger, and it carries
no actor identity. So observability consumers (`gakudan_metrics`,
`gakudan_otel`) are best-effort by design, and that is fine for metrics and
traces - but not for compliance evidence.

The design tension is the usual one. gakudan should own the **seam** and a
sane default sink; the retention policy, the redaction rules, and the choice
of sink (a database, a SIEM, a Kafka topic) belong to the consumer. gakudan
must not become a compliance product.

## Decision

A **hybrid** model: a synchronous, guaranteed core seam for the small set of
must-not-lose events, and the existing best-effort telemetry for everything
else. The two are complementary - audit answers "what is the record of
record"; telemetry answers "what is the system doing right now".

### Actor identity in `run_config`

```erlang
gakudan:start_run(#{
    agents => [...], router => ..., llm => ...,
    actor => #{id => ~"u_123", tenant => ~"team_payments"}
}).
```

`actor` is an optional, opaque map. gakudan never interprets it; it threads it
verbatim into every audit event and into run-lifecycle telemetry metadata. The
soft convention is `#{id => binary(), tenant => binary()}` plus whatever the
consumer needs, but no shape is enforced. Omitting it behaves exactly as today.

### A `gakudan_audit` behaviour

```erlang
-callback init(Opts :: map()) -> {ok, State :: term()} | {error, term()}.
-callback record(State :: term(), event()) -> ok | {error, term()}.

event() :: #{
    type := event_type(),
    run_id := gakudan:run_id(),
    timestamp := integer(),          %% system_time(millisecond)
    actor => map(),
    agent_id => gakudan_agent:id(),
    turn => non_neg_integer(),
    detail => map()
}.

event_type() :: run_started | run_stopped | run_interrupted | run_resumed
              | guardrail_allow | guardrail_block | guardrail_transform.
```

A sink owns an opaque `State` (a kura repo, a socket, a file handle), exactly
like `gakudan_checkpointer`. The seam is configured per run or as an app-env
default, mirroring the checkpointer:

```erlang
%% per run
audit => {gakudan_audit_kura, #{repo => my_repo, on_error => fail_closed}}
%% or app env
{gakudan, [{default_audit, {gakudan_audit_kura, #{repo => my_repo}}}]}
```

With no sink configured, every audit call is a no-op - zero cost, behaves as
today.

### Synchronous, with an explicit failure policy

Audit events are recorded **inline, before the action proceeds**, in the
process that owns the event (the run statem for lifecycle events, the turn
worker for guardrail events). The `on_error` opt picks what happens when the
sink write fails:

- `log` (default) - log a warning and continue. Best-effort, but a *tried*
  synchronous write, which is strictly stronger than a dropped telemetry
  event.
- `fail_closed` - raise. The action does not proceed without its record. In
  the statem this fails the run (its one_for_all supervisor decides what
  happens next); in a turn worker it fails that turn, which is recorded as a
  turn failure and leaves the run able to continue. Intended for shops that
  would rather halt than lose an audit record.

### Events covered by the core seam

| Event | Where it fires | Detail |
| --- | --- | --- |
| `run_started` | statem, fresh init | `#{mode => fresh}` |
| `run_resumed` | statem, human resume / supervised restart | `#{mode => human \| supervised, origin => ...}` |
| `run_interrupted` | statem, on `interrupt/2` | `#{reason => Reason}` |
| `run_stopped` | statem, `terminate` (always best-effort) | `#{reason => Reason}` |

`run_stopped` is the one event that ignores `fail_closed` and is always
recorded best-effort: it fires from `terminate/3`, where there is no action
left to gate, so a sink failure must never turn a clean stop into a crash.
| `guardrail_allow` | turn worker, per guardrail | `#{guardrail => Mod, stage => Stage}` |
| `guardrail_transform` | turn worker, per guardrail | `#{guardrail => Mod, stage => Stage}` |
| `guardrail_block` | turn worker, per guardrail | `#{guardrail => Mod, stage => Stage, reason => Reason}` |

To carry the per-guardrail decision without giving the guardrail module an
audit dependency, `gakudan_guardrail:run/4` now returns a **decision trail**
alongside its result: `{ok, Payload, Trail}` / `{block, {Mod, Reason}, Trail}`
where `Trail :: [{module(), allow | transform}]`. The turn replays the trail
into audit events. The trail never carries payloads - only which guardrail
decided what - so no message content leaks into it.

### What is deliberately *not* in an audit event

Payload content. A `run_resumed` event records that a human resumed and (for a
binary payload) its byte size, not the text; a guardrail event records the
decision, not the message. Content lives in the transcript / checkpointer,
where the consumer applies its own redaction and retention. Keeping content
out of the audit ledger by default means the ledger itself is not a new PII
sink.

### The default sink: `gakudan_audit_kura`

Ships in core next to `gakudan_checkpointer_kura` (kura is already a core
dep, so this needs no new dependency and no separate repo). It writes one
append-only row per event to a `gakudan_audit` table. `actor.id` and
`actor.tenant` are lifted into their own columns so the common query - "every
action by this actor / tenant" - is a plain indexed lookup; the full event is
also stored as a `term_to_binary` blob.

Row ids are time-ordered (`aud-<zero-padded-ms>-<rand>`), so `list/2` returns
a run's events oldest-first by id even when several share a whole-second
`inserted_at`. (UUIDv7 via `jhn_uuid` would serve the same role if that dep is
later pulled into core.)

**Integrity.** Each row stores `event_hash = sha256(deterministic(event))`,
which detects after-the-fact modification of a row; `verify/2` rescans a run's
rows and recomputes the hashes (`list/2` returns the decoded events). Full
hash-*chaining* (each row hashing the
previous, so deletion and insertion are also detectable) needs a serialized
writer, because a fanout emits audit writes from concurrent turn-worker
processes and a read-then-chain race would fork the chain. That serialization
is deliberately deferred; v1 ships per-row hashing, which is honest about what
it guarantees. A sink with a dependency core must not carry (Kafka, a SIEM
exporter) is the case for a future sister lib; it is not needed for the
default.

## Consequences

**Positive.**

- A durable, queryable, tamper-evident record keyed by run and attributable to
  an actor/tenant - the concrete adoption gate for regulated operators.
- The seam is pluggable and optional, exactly like the checkpointer, llm
  backend, and guardrails. Zero cost when no sink is configured.
- Content stays out of the ledger by default, so audit does not widen the
  data-at-rest surface.
- The guardrail decision trail also makes `guardrail_transform` (a redaction
  actually happening) observable, which telemetry only exposed for blocks.
- Per-row hashing detects row edits but not row deletion; full chaining is
  deferred (see the default-sink note). Operators needing deletion-evidence
  today should point the sink at append-only / WORM storage.

**Negative.**

- `gakudan_guardrail:run/4` changes its return arity. It is internal (only the
  turn calls it), so no public contract breaks, but the change is noted here.
- `fail_closed` on a run-lifecycle event can fail the run if the sink is down;
  with a supervised restart this can loop. Documented; `fail_closed` is opt-in
  and an operator choosing it accepts halt-over-lose.
- A synchronous sink write is on the critical path of run start/stop and every
  guardrail decision. The cost is the sink implementation's, not the library's;
  the default kura sink is one insert per event.
