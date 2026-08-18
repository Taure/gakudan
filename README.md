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
| Router | `gakudan_router` | `round_robin`, `handoff`, `manager`, `loop`, `auto` | Decides whose turn is next. |
| Blackboard | (private) | gen_server + ETS | Append-only transcript with subscriber pub/sub. |
| Tool | `gakudan_tool` | bring your own | JSON schema + `run/1` callback. Tool calls in a turn run in parallel. |
| LLM backend | `gakudan_llm` | `anthropic`, `gemini`, `vertex`, `stub`, `fallback`, `retry` | One callback: `complete(req, opts) -> response`. |
| Validator | `gakudan_validator` | `json` | Validates structured (`response_format`) output against a schema. |
| Context transform | `gakudan_context` | `trim` | Compacts the transcript before each LLM call. |
| Guardrail | `gakudan_guardrail` | bring your own | Allow / block / transform at the LLM boundary. |
| Audit sink | `gakudan_audit` | `kura` | Durable, synchronous record of lifecycle + policy events. |
| MCP client | `gakudan_mcp_client` | - | Speaks MCP Streamable HTTP; one gen_server per endpoint; exposes discovered tools for use in agents. |

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

Both `gakudan_llm_anthropic` and `gakudan_llm_gemini` accept a `base_url` in
their `Opts`, so a run can route through an LLM gateway / proxy (for example
[sekisho](https://github.com/Taure/sekisho) for virtual keys, budgets, and
audit) without any code change:

```erlang
llm => {gakudan_llm_anthropic, #{base_url => ~"https://sekisho.internal/anthropic"}}
```

## Generation options and structured output

An agent can set per-request generation options via the optional
`request_options/0` callback; backends map them to provider-native fields:

```erlang
request_options() ->
    #{
        temperature    => 0.2,
        max_tokens     => 1024,
        stop_sequences => [~"\n\n"],
        tool_choice    => any,           %% auto | any | none | {tool, Name}
        response_format => #{            %% a JSON schema -> schema-constrained output
            type => ~"object",
            properties => #{score => #{type => ~"integer"}},
            required => [~"score"]
        },
        validator => {gakudan_validator_json, Schema}   %% optional, validates the result
    }.
```

When `response_format` is set, the parsed object is validated (if a
`validator` is given), written to the blackboard under the
`structured_output` key, and appended to the transcript as JSON. Bring your
own `gakudan_validator` module to validate against anything; the JSON-schema
default covers `type`/`required`/`properties`/`items`/`enum`. See
[ADR 0016](docs/adr/0016-llm-request-options.md) and
[ADR 0017](docs/adr/0017-structured-output-validation.md).

## Resilience: fallback and retry

Resilience is composable LLM backends - no core changes. Wrap your backend
spec to fall through to alternatives, retry transient errors, or both:

```erlang
llm => {gakudan_llm_fallback, #{
    backends => [
        {gakudan_llm_retry, #{backend => {gakudan_llm_anthropic, #{}}, max_attempts => 3}},
        {gakudan_llm_vertex, #{project => P, location => L, token_fun => F}}
    ]
}}
```

`retry` backs off exponentially on 5xx / timeout / connection errors only;
`fallback` tries each backend in order and never falls through a user
cancel. See [ADR 0018](docs/adr/0018-resilient-llm-backends.md).

## Context compaction

By default the full transcript is replayed every turn. Set a `context`
transform to compact it just before each LLM call:

```erlang
context => {gakudan_context_trim, #{max_tokens => 8000, keep_first => 1}}
```

The default trims oldest entries to fit a token budget (pinning the first N);
implement `gakudan_context` to summarise or retrieve instead. See
[ADR 0019](docs/adr/0019-context-compaction.md).

## Fork from a checkpoint

With a checkpointer configured, branch a new run from any persisted step of
an existing run - the source run is untouched:

```erlang
{ok, _Sup, NewRunId} = gakudan:start_run(Config#{fork_from => {SourceRunId, StepId}}).
```

The new run rehydrates the source transcript as of that step and continues
under a fresh id. See [ADR 0021](docs/adr/0021-fork-from-checkpoint.md).

## Examples

| Example | What it shows |
| --- | --- |
| [`planner_coder`](examples/planner_coder) | Two-agent handoff with a tool. Planner breaks the task into steps and hands off to a coder via `@coder`; the coder uses a `write_snippet` tool. |
| [`debate`](examples/debate) | Three agents and a custom router. The 60-second tour above. |

Both ship a `run_stub/0` for offline use and a `run/0,1` against the real
Anthropic API. `debate` also has `eval_stub/0` that drives `gakudan_eval`
end-to-end.

## MCP client

`gakudan_mcp_client` is a gen_server that speaks the
[Model Context Protocol](https://modelcontextprotocol.io/) Streamable HTTP
transport. Start one process per remote MCP server under your application's
supervision tree:

```erlang
{ok, _Pid} = gakudan_mcp_client:start_link(#{
    name      => my_github_mcp,
    transport => http,
    base_url  => ~"https://mcp.internal/github",
    auth      => {bearer, ~"<token>"}
}).
```

For OAuth-gated MCP servers, use the OAuth 2.1 client-credentials grant
instead of a static bearer token:

```erlang
auth => {oauth2, #{
    token_url     => ~"https://auth.example.com/oauth/token",
    client_id     => ~"...",
    client_secret => ~"...",
    scope         => ~"mcp.read mcp.tools"   %% optional
}}
```

The access token is fetched on first use, cached until expiry (minus a 30s
skew), and refreshed automatically. A `401` response triggers a one-shot
refetch-and-retry so a revoked token self-heals without manual intervention.

Use `as_tools/1` to expose all of the server's discovered tools to an agent:

```erlang
tools() ->
    [my_local_tool | gakudan_mcp_client:as_tools(my_github_mcp)].
```

Or reference individual MCP tools by name:

```erlang
tools() ->
    [
        my_local_tool,
        {gakudan_mcp_tool, #{client => my_github_mcp, name => ~"search_repos"}},
        {gakudan_mcp_tool, #{client => my_github_mcp, name => ~"read_file"}}
    ].
```

Public operations on the client: `list_tools/1`, `get_tool/2`,
`call_tool/3`, `as_tools/1`, `stop/1`. Tool calls are synchronous; a
per-tool `timeout_ms` option (default 30 s) cancels the HTTP request and
returns `{error, timeout}` on a slow server.

See [ADR 0006](docs/adr/0006-mcp-client.md) and
[ADR 0015](docs/adr/0015-mcp-oauth.md).

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

## Persistence

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

The kura backends ship in companion libraries: add **`kura_postgres`**
(production) or **`kura_sqlite`** (local / embedded) to your `rebar.config`
deps - gakudan core is driver-agnostic and pulls no database driver itself.
gakudan defines the schema as kura migrations (`gakudan_runs`,
`gakudan_steps`, `gakudan_tool_results`, `gakudan_audit`, under
`migrations/`); apply them to your database before first use.

Run config can also pass `checkpointer => {Mod, Opts}` per-run to override
the default. Without a checkpointer, runs are in-memory only.

`gakudan:interrupt(RunId, Reason)` pauses a run and persists the
snapshot. `gakudan:resume(RunId, Payload)` hands a `user`-role entry back
to the loop. See [ADR 0004](docs/adr/0004-resume-interrupt-idempotency.md).

`initial_messages` on `start_run/1` lets callers inject RAG output / doc
grounding into the blackboard before the first turn fires.

## Horizontal scale-out (run leasing)

Because runs are recoverable state in a shared database, several gakudan
nodes can share one Postgres for horizontal scale-out and high
availability - no BEAM clustering. Each run is owned by at most one node
via a lease that is renewed by a heartbeat and reclaimed on expiry, so a
dead node's runs are picked up by another within one lease TTL. A node
that loses its lease fences itself: ownership-conditional writes are
refused with `{error, lease_lost}`, which composes with idempotent tool
replay to keep side effects exactly-once. See
[ADR 0023](docs/adr/0023-run-leasing.md).

Leasing is off by default. Turn it on with a `lease` map (requires a
Postgres-class backend - it relies on `FOR UPDATE SKIP LOCKED`):

```erlang
%% sys.config
{gakudan, [
    {default_checkpointer, {gakudan_checkpointer_kura, #{repo => my_repo}}},
    {lease, #{
        enabled => true,
        owner_id => ~"node-a",        % default: node() + a per-boot token
        ttl_ms => 30000,
        renew_interval_ms => 10000,
        claim_interval_ms => 15000,
        claim_batch => 50
    }}
]}.
```

Run new agents on whichever node a load balancer picks; orphaned runs
migrate on their own. Configure a stable `owner_id` per node in
production.

## Streaming

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

`gakudan:cancel(RunId)` stops an in-flight generation: the backend request
is aborted, subscribers see a `{cancelled, _}` event, and the run returns to
`idle`. The pubsub also sheds load - a subscriber whose mailbox grows past
`stream_max_queue` (default 10000) has events dropped, with a `{dropped, N}`
marker folded into its next delivery, so one slow consumer can't sink the
stream. See [ADR 0014](docs/adr/0014-streaming-cancellation-backpressure.md).

## Audit logging

Telemetry is best-effort; an audit sink is synchronous and recorded
before the action proceeds, so a regulated operator has a durable record
of *who* started a run, *which* policy decisions fired, and *when* a human
intervened. Configure a sink and attach an actor:

```erlang
{ok, _Pid, RunId} = gakudan:start_run(#{
    agents => [...], router => ..., llm => ...,
    actor => #{id => ~"u_123", tenant => ~"team_payments"},
    audit => {gakudan_audit_kura, #{repo => my_repo, on_error => fail_closed}}
}).
```

The default `gakudan_audit_kura` sink writes one append-only row per event
(any kura backend), lifting `actor.id` and `actor.tenant` into their own
columns and hashing each row into a per-run chain. The chain is unkeyed and
stored alongside the data it protects, so it detects corruption and casual
tampering, not an attacker with write access - see `m:gakudan_audit_kura` and
issue #68. Events covered:
`run_started`, `run_resumed`, `run_interrupted`, `run_stopped`, and every
guardrail decision (`guardrail_allow` / `guardrail_transform` /
`guardrail_block`). `on_error` is `log` (warn and continue) or
`fail_closed` (halt rather than lose a record). With no sink configured
audit is a no-op. The default sink uses the same kura backend as the
checkpointer, so it needs `kura_postgres` / `kura_sqlite` too (see
Persistence). Bring your own sink by implementing the `gakudan_audit`
behaviour. Full design in [ADR 0012](docs/adr/0012-audit-logging.md).

## Cost budgets

Token telemetry makes spend observable; a budget makes it *enforceable*. A
budget is checked before each turn is dispatched and stops the run before it
spends past a ceiling:

```erlang
{ok, _Pid, RunId} = gakudan:start_run(#{
    agents => [...], router => ..., llm => ...,
    budget => {gakudan_budget_limit, #{max_tokens => 100000, max_llm_calls => 50}}
}).
```

The built-in `gakudan_budget_limit` covers the universal caps -
`max_tokens`, `max_input_tokens`, `max_output_tokens`, `max_llm_calls`,
`max_turns`. On a breach the run stops with reason
`{budget_exceeded, {Mod, Reason}}` (graceful), records a `system` entry, and
emits a `[gakudan, budget, exceeded]` telemetry event. Money and per-tenant
caps are yours - implement the `gakudan_budget` behaviour's `check/2` against
your own price table or counters. With no budget configured it is a no-op.
See [ADR 0013](docs/adr/0013-cost-budgets.md).

## Companion libraries

| Library | What it adds |
| --- | --- |
| [`gakudan_metrics`](https://github.com/Taure/gakudan_metrics) | Prometheus exporter + starter Grafana dashboard. |
| [`kura_postgres`](https://github.com/Taure/kura_postgres) | Postgres backend for the checkpointer + audit sink. |
| [`kura_sqlite`](https://github.com/Taure/kura_sqlite) | SQLite backend for local / embedded persistence. |
| `gakudan_liveboard` (planned) | Real-time human-readable view of runs, via Arizona. |

## Status

Single-node. Shipped: persistence via the checkpointer behaviour,
human-in-the-loop interrupt / resume, token-level streaming, parallel agent
fanout, an MCP client with OAuth 2.1 client-credentials auth, pluggable
guardrails, and synchronous audit logging.
No multi-node distribution (out of scope by design).

## Why "gakudan"?

楽団 - Japanese for orchestra. Fits the agent-coordination metaphor.
