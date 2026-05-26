# gakudan

[![CI](https://github.com/Taure/gakudan/actions/workflows/ci.yml/badge.svg)](https://github.com/Taure/gakudan/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/Taure/gakudan)](LICENSE)
[![Erlang](https://img.shields.io/badge/erlang-29%2B-blue)](.tool-versions)

Multi-agent collaboration primitives for the BEAM.

A small OTP library for running collaborations between specialised LLM agents.
Each agent is an Erlang module. A router decides whose turn is next. A
blackboard holds the shared transcript. The whole thing is wrapped in a
supervision tree, one tree per run.

## 60-second tour

No API key required. The example uses a deterministic stub LLM backend that
returns canned responses so you can see the whole multi-agent flow run
end-to-end with zero setup, zero cost.

```bash
git clone https://github.com/Taure/gakudan.git
cd gakudan
rebar3 as example shell
```

```erlang
1> application:ensure_all_started(gakudan).
2> debate:run_stub().
```

Three agents collaborate. `proponent` argues FOR, `opponent` argues AGAINST,
`synthesiser` summarises and recommends. A custom router cycles the debaters
for two rounds then forces one synthesiser turn:

```
=== debate ===
[user]
Should gakudan eval cases support JSON in v0.2?

[proponent]
FOR: JSON cases let non-Erlang teams author evals. A Python team can dump
replay logs as JSON without ever touching rebar3.

[opponent]
AGAINST: JSON loses Erlang's pattern-match expressiveness in expectations.
You end up re-inventing a poor cousin of Erlang term syntax.

[proponent]
FOR (continued): A JSON schema is testable independently of any BEAM
toolchain. Doc-as-test becomes a thing for free.

[opponent]
AGAINST (continued): Tooling cost is real. JSON parsing, schema validation,
version migration. Maintenance debt the project has not earned yet.

[synthesiser]
Strongest points
- FOR: non-BEAM contributors; schema is independently testable.
- AGAINST: Erlang terms keep matcher expressiveness; tooling debt is concrete.

Crux: who actually authors eval cases? If only BEAM devs, stay Erlang-term.
If non-BEAM contributors are expected, JSON.

Recommendation: hold off on JSON until a real non-BEAM contributor wants to
author a case. Not yet earned.
```

Swap in `planner_coder:run_stub()` for a two-agent handoff with a tool call.

## What's in the box

| Component | Behaviour | Built-ins | What it does |
| --- | --- | --- | --- |
| Run | (private) | one supervision tree per run | A single collaboration session, crash-isolated. |
| Agent | `gakudan_agent` | bring your own | A role: system prompt, model, tools, id. |
| Router | `gakudan_router` | `round_robin`, `handoff`, `manager` | Decides whose turn is next. |
| Blackboard | (private) | gen_server + ETS | Append-only transcript with subscriber pub/sub. |
| Tool | `gakudan_tool` | bring your own | JSON schema + `run/1` callback. |
| LLM backend | `gakudan_llm` | `anthropic`, `gemini`, `stub` | One callback: `complete(req, opts) -> response`. |

## Writing a custom router

A router decides whose turn is next. Implement the `gakudan_router` behaviour
in your own module and pass it via `router => {your_router, Opts}` in
`start_run/1`.

```erlang
-module(my_router).
-behaviour(gakudan_router).
-export([init/2, next/2]).

init(Opts, AgentIds) ->
    {ok, #{queue => AgentIds, opts => Opts}}.

next(#{queue := [Next | Rest]} = State, _Transcript) ->
    {next, Next, State#{queue := Rest}};
next(#{queue := []} = State, _Transcript) ->
    {done, State}.
```

`next/2` returns `{next, AgentId, NewState}` to schedule another turn, or
`{done, NewState}` to end the run. See [`debate_router`](examples/debate/src/debate_router.erl)
for a fuller example (N rounds of debaters + a forced synthesiser turn).

## Running against a real model

Set `ANTHROPIC_API_KEY` (or `GEMINI_API_KEY`), then:

```erlang
{ok, _Pid, RunId} = gakudan:start_run(#{
    agents => [planner, coder],
    router => {gakudan_router_handoff, #{start => planner}},
    llm    => {gakudan_llm_anthropic, #{}}
}),
ok = gakudan:send(RunId, ~"Write me a TCP echo server in Erlang."),
{ok, Entries} = gakudan:await(RunId, 90_000).
```

The Anthropic backend marks the system prompt and tool definitions with
`cache_control: ephemeral` automatically, so multi-turn runs hit prompt
caching at ~10% of the uncached input-token rate. The Gemini backend
translates request/response shape transparently; agents declare their model
via the `model/0` callback.

## Examples

| Example | What it shows |
| --- | --- |
| [`planner_coder`](examples/planner_coder) | Two-agent handoff with a tool. Planner breaks the task into steps and hands off to a coder via `@coder`; the coder uses a `write_snippet` tool. |
| [`debate`](examples/debate) | Three agents and a custom router. The 60-second tour above. |

Both ship a `run_stub/0` for offline use and a `run/0,1` against the real
Anthropic API. `debate` also has `eval_stub/0` that drives `gakudan_eval`
end-to-end.

## Evals

`gakudan_eval:run/1` takes a case spec (config + scripted LLM responses +
expectations) and returns a structured pass/fail report. Stub-driven, zero
API cost, deterministic, drop-in for CT or eunit.

```erlang
ok = gakudan_eval:assert_passed(gakudan_eval:run(#{
    config => #{
        agents => [planner_mod, coder_mod],
        router => {gakudan_router_handoff, #{start => planner}},
        max_turns => 4
    },
    script => [
        {text, ~"Plan: ... @coder please continue."},
        {text, ~"acknowledged."}
    ],
    input => ~"Build me a TCP echo server",
    expect => [
        {outcome, idle},
        {min_turns, 2},
        {agent_turn_contains, planner, ~"Plan"},
        {agent_turn_contains, coder, ~"acknowledged"}
    ]
})).
```

Matcher vocabulary in [`docs/adr/0002-eval-harness.md`](docs/adr/0002-eval-harness.md).

## Observability

`gakudan` emits `:telemetry` events at every run, turn, LLM request, tool
call, and router decision boundary. `[gakudan, llm, request, stop]` carries
`tokens_in` and `tokens_out`, so per-team cost telemetry comes for free.

```erlang
telemetry:attach(my_handler, [gakudan, llm, request, stop], fun(_, M, Meta, _) ->
    io:format("~p used ~p in / ~p out tokens~n",
              [maps:get(agent_id, Meta), maps:get(tokens_in, M), maps:get(tokens_out, M)])
end, undefined).
```

Full event surface in [`docs/adr/0001-telemetry-events.md`](docs/adr/0001-telemetry-events.md);
public API from v0.1 onward.

## Persistence (v0.2)

Runs survive a BEAM restart when a checkpointer is configured. The
default impl uses `kura` and works against any kura backend
(`kura_postgres` for prod, `kura_sqlite` for local / embedded).

```erlang
%% sys.config
[{kura, [
    {dialect, kura_dialect_pg},
    {repos, #{
        my_repo => #{backend => kura_backend_postgres, database => "my_app"}
    }}
]},
 {gakudan, [
    {default_checkpointer, {gakudan_checkpointer_kura, #{repo => my_repo}}}
]}].
```

Run config can also pass `checkpointer => {Mod, Opts}` per-run to override
the default. Without a checkpointer, runs behave as in v0.1 (in-memory only).

`gakudan:interrupt(RunId, Reason)` pauses a run and persists the
snapshot. `gakudan:resume(RunId, Payload)` hands a `user`-role entry back
to the loop. See [ADR 0004](docs/adr/0004-resume-interrupt-idempotency.md).

`initial_messages` on `start_run/1` lets callers inject RAG output / doc
grounding into the blackboard before the first turn fires.

## Streaming (v0.3)

Subscribe to a run to receive token-by-token deltas as they arrive from
the backend:

```erlang
{ok, _Ref} = gakudan:subscribe_stream(RunId),
receive
    {gakudan_stream, RunId, #{payload := {text_delta, Chunk}}} ->
        io:format("~s", [Chunk])
end.
```

Backends that do not implement `gakudan_llm:stream_call/3` fall back to
`complete/2` wrapped in a single `text_delta` event, so the API is
uniform whether the underlying provider streams or not. Full event
catalogue in [ADR 0005](docs/adr/0005-streaming.md).

## Companion libraries

| Library | What it adds |
| --- | --- |
| [`gakudan_metrics`](https://github.com/Taure/gakudan_metrics) | Prometheus exporter + starter Grafana dashboard. |
| `gakudan_liveboard` (planned) | Real-time human-readable view of runs, via Arizona. |

## Status

v0.2 - single-node persistence via checkpointer behaviour; human-in-the-loop
interrupt / resume. No multi-node distribution, no streaming responses yet.

## Why "gakudan"?

楽団 - Japanese for orchestra. Fits the agent-coordination metaphor.
