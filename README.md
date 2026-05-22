# gakudan

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

## Try it (offline, no API key)

```bash
git clone https://github.com/Taure/gakudan.git
cd gakudan
rebar3 as example shell
1> application:ensure_all_started(gakudan).
2> planner_coder:run_stub().
```

You'll see a planner agent break the task into steps, hand off to a coder
agent (via `@coder` token), which uses a `write_snippet` tool to drop the code
in `/tmp/gakudan_snippets/`.

## Try it (real Anthropic)

```bash
export ANTHROPIC_API_KEY=sk-ant-...
rebar3 as example shell
1> application:ensure_all_started(gakudan).
2> planner_coder:run().
```

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

A companion `gakudan_metrics` library (Prometheus + Grafana dashboard) is
planned.

## Status

v0.1 - single-node only. No multi-node distribution, no built-in dashboard.
A companion `gakudan_liveboard` (Arizona) is planned. Streaming responses
land in v0.2.

## Why "gakudan"?

楽団 - Japanese for orchestra. Fits the agent-coordination metaphor.
