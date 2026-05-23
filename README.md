# gakudan

[![CI](https://github.com/Taure/gakudan/actions/workflows/ci.yml/badge.svg)](https://github.com/Taure/gakudan/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/Taure/gakudan)](LICENSE)
[![Erlang](https://img.shields.io/badge/erlang-28%2B-blue)](.tool-versions)

Multi-agent collaboration primitives for the BEAM.

`gakudan` is a small OTP library for running collaborations between specialised
LLM agents. Each agent is an Erlang module implementing the `gakudan_agent`
behaviour. A *router* decides whose turn is next. A *blackboard* holds the
shared transcript. The whole thing is wrapped in a supervision tree, one tree
per run.

```erlang
{ok, _Pid, RunId} = gakudan:start_run(#{
    agents => [planner, coder],
    router => {gakudan_router_handoff, #{start => planner}},
    llm    => {gakudan_llm_anthropic, #{}}
}),
ok = gakudan:send(RunId, ~"Write me a TCP echo server in Erlang."),
{ok, Entries} = gakudan:await(RunId, 90_000).
```

## What's in the box

| Component | Behaviour | Built-ins |
| --- | --- | --- |
| Agent | `gakudan_agent` | bring your own |
| Router | `gakudan_router` | `round_robin`, `handoff`, `manager` |
| Tool | `gakudan_tool` | bring your own |
| LLM backend | `gakudan_llm` | `anthropic`, `stub` |

## Examples

| Example | What it shows |
| --- | --- |
| [`planner_coder`](examples/planner_coder) | Two-agent handoff with a tool. Planner breaks the task into steps and hands off to a coder via `@coder`; the coder writes the snippet to disk. |
| [`debate`](examples/debate) | Three agents and a custom router. Proponent argues FOR, opponent argues AGAINST, synthesiser summarises and recommends. Tool-free; demonstrates writing your own `gakudan_router`. |

Both examples ship a `run_stub/0` for offline use, a `run/0,1` against the
real Anthropic API, and (for `debate`) an `eval_stub/0` that drives
`gakudan_eval` end-to-end.

```bash
git clone https://github.com/Taure/gakudan.git
cd gakudan
rebar3 as example shell
1> application:ensure_all_started(gakudan).
2> planner_coder:run_stub().     %% offline
3> debate:run_stub().            %% offline
4> debate:eval_stub().           %% prints the eval report
```

Set `ANTHROPIC_API_KEY` and call `planner_coder:run/0` or
`debate:run/1` to drive them against the real model.

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

The matcher vocabulary is documented in [`docs/adr/0002-eval-harness.md`](docs/adr/0002-eval-harness.md).

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

The full event surface is documented in [`docs/adr/0001-telemetry-events.md`](docs/adr/0001-telemetry-events.md)
and is part of the stable public API from v0.1 onward.

## Companion libraries

| Library | What it adds |
| --- | --- |
| [`gakudan_metrics`](https://github.com/Taure/gakudan_metrics) | Prometheus exporter + starter Grafana dashboard. |
| `gakudan_liveboard` (planned) | Real-time human-readable view of runs, via Arizona. |

## Status

v0.1 - single-node only. No multi-node distribution, no built-in dashboard.
A companion `gakudan_liveboard` (Arizona) is planned. Streaming responses
land in v0.2.

## Why "gakudan"?

楽団 - Japanese for orchestra. Fits the agent-coordination metaphor.
