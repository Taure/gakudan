# 2. Eval harness

Date: 2026-05-22

## Status

Accepted (v0.1).

## Context

Agents are non-deterministic. The same prompt against the same model can
produce different transcripts on different days. For a library that wants
to be usable in regulated code paths, in CI, and as a learning surface for
agent authors, we need a way to assert "this collaboration still does what
we expect" without burning real API credits.

Two pieces are already in place:

1. `gakudan_llm_stub` plus `gakudan_llm_stub_script` give us deterministic
   LLM responses, scripted as a queue.
2. The telemetry event surface from ADR 0001 surfaces every run, turn, LLM
   request, tool call, and router decision with a stable shape.

Combining them gives us replayable runs whose entire behaviour can be
asserted against. The eval harness is the public face of that combination.

## Decision

`gakudan_eval:run/1` takes a single case map and returns
`{ok, Report} | {error, Report}`.

### Case shape

```erlang
#{
    name => binary() | atom(),
    config := gakudan_run_config_without_llm(),
    script := [gakudan_llm_stub:response()],
    input := binary(),
    timeout => timeout(),   %% default 5000
    expect := [expectation()]
}
```

The harness substitutes `gakudan_llm_stub` for the `llm` slot in `config`,
pointing it at the script gen_server it spins up for the case. Callers may
pre-set `llm` if they want a non-stub backend (e.g. a recorded-response
adapter), but the default is stub-only and offline.

### Expectation language

A small, finite set of matchers. Adding new ones is a minor-version bump.

- `{outcome, idle | running | completed}` — final state of the run.
- `{min_turns, N}` / `{max_turns, N}` — bounds on `[gakudan, turn, stop]`
  count.
- `{agent_turn_contains, AgentId, Substring}` — at least one transcript
  entry from that agent contains the substring.
- `{agent_turn_count, AgentId, N}` — exact number of transcript entries
  from that agent.
- `{tokens_input_at_least, N}` / `{tokens_output_at_least, N}` — sums of
  `tokens_in` / `tokens_out` measurements across
  `[gakudan, llm, request, stop]` events.
- `{tool_called, ToolName}` — at least one `[gakudan, tool, run, stop]`
  with that tool name.
- `no_failed_turns` — zero `[gakudan, turn, stop]` events with
  `outcome => failed`.
- `{transcript_min_length, N}` — bound on total entries.

Unknown expectation atoms are themselves failures. Cases catch typos
without silently passing.

### Report shape

```erlang
#{
    name        => binary() | atom(),
    transcript  := [gakudan_blackboard:entry()],
    telemetry   := [{event_name(), measurements(), metadata()}],
    duration_ms := non_neg_integer(),
    outcome     := idle | running | completed | {error, term()},
    passed      := [expectation()],
    failed      := [{expectation(), term()}]
}
```

The `transcript` and `telemetry` fields make `Report` self-contained
debugging output when an eval fails. Tooling can render diffs against an
expected report.

### `assert_passed/1`

A one-liner integration hook for CT and eunit:

```erlang
Result = gakudan_eval:run(Case),
ok = gakudan_eval:assert_passed(Result).
```

Crashes with `{eval_failed, Name, FailedExpectations}` on any failure.

## Consequences

**Positive.**

- Tests against agent behaviour become first-class, not glued together
  per-project.
- Cost telemetry (token sums) is asserted from the same source the
  production exporter reads. The exporter is its own consumer; the eval
  harness is another. Both pin against ADR 0001.
- The harness is a learning surface: authors of new agents iterate
  against eval cases in milliseconds, with zero LLM cost.
- CI can gate merges on "no agent behaviour regression" by treating evals
  as test cases.

**Negative.**

- The expectation vocabulary will grow over time. We keep it small in v0.1
  on purpose; resist new matchers unless several real cases need them.
- Stub-driven evals do not catch regressions caused by real LLMs changing
  their output style. Live-recording adapters can fill that gap later
  (out of scope for v0.1).
