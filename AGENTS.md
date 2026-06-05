# AGENTS.md

Working agreement for agents and contributors on **gakudan** - multi-agent
collaboration primitives for the BEAM. A small OTP library: no Nova or Arizona
in core, no DSL, bring-your-own everything.

## Ecosystem

Part of a BEAM-native multi-agent stack (all under https://github.com/Taure):

- **gakudan** - agent orchestration runtime: per-run supervision, pluggable
  routers/tools/LLM-backends, MCP *client*, persistence, streaming, guardrails,
  audit, cost budgets.
- **[saiten](https://github.com/Taure/saiten)** - runtime-agnostic eval/scoring
  + CI gate: grades any output (a gakudan run, a raw API call, a Claude Code
  transcript) with deterministic + LLM-judge scorers.
- **[madoguchi](https://github.com/Taure/madoguchi)** - MCP *server* framework:
  expose any BEAM service as MCP tools; the server counterpart to this repo's
  MCP client.
- **[sekisho](https://github.com/Taure/sekisho)** - LLM gateway / control plane:
  virtual keys, budgets, and audit in front of Anthropic + OpenAI (chat **and
  embeddings**) + Vertex.
- **[bunko](https://github.com/Taure/bunko)** - agent memory + RAG (pgvector).
- **[banto](https://github.com/Taure/banto)** - multi-agent repo concierge; the
  showcase consumer that wires the pillars together.

Sister libs: **gakudan_metrics** (Prometheus + Grafana), **gakudan_otel**
(OpenTelemetry spans), **gakudan_tickets** + **gakudan_tickets_github**
(ticket-source adapters), **gakudan_liveboard** (live run dashboard).

**This repo** is the runtime at the centre of the stack. It ships the MCP
*client* (madoguchi is the server side); saiten grades its runs; sekisho can sit
behind its `gakudan_llm` backends (point `gakudan_llm_anthropic` /
`gakudan_llm_gemini` at the gateway with a `base_url` opt); the sister libs plug
into its telemetry, ticket, and dashboard seams.

## Design pillars

- **Primitives, not a framework.** A handful of behaviours (agent, router,
  tool, llm) and a supervision tree.
- **OTP-shaped.** Each run is a supervisor; the run state machine is a
  `gen_statem`; the blackboard is a `gen_server` owning ETS.
- **Pluggable everything.** Routers, tools, LLM backends, checkpointers, audit
  sinks, guardrails, and budgets all swap freely.
- **Library, not application.** Bring your own dashboard / persistence / auth.

## Scope - what belongs here

- **In:** the behaviours, the run / blackboard / router / turn machinery, the
  LLM adapters (Anthropic, Gemini, Vertex, stub), streaming, persistence, the
  MCP client, guardrails, audit, budgets, the examples.
- **Out:** BEAM clustering / distributed Erlang (no `net_kernel`, global
  registry, or run migration). Horizontal scale-out and HA are done by
  shared-nothing nodes coordinating through the shared checkpointer store
  (run leasing, [ADR 0023](docs/adr/0023-run-leasing.md)), not by clustering.
  Also out: a web dashboard (that is `gakudan_liveboard`); app-specific
  persistence schemas or auth.
- **Out forever:** anything that warps the library for a single consumer. If a
  change is driven by one app's need, it probably belongs in that app. When in
  doubt, keep gakudan general-purpose.

## Commands

```bash
rebar3 compile
rebar3 eunit
docker compose up -d   # Postgres for the kura suite (gakudan_kura_SUITE)
rebar3 ct              # skips the kura suite cleanly when no DB is reachable
rebar3 fmt             # erlfmt (write); CI runs fmt --check
rebar3 xref
rebar3 dialyzer
rebar3 ex_doc          # fix any new warnings
rebar3 as example shell   # then planner_coder:run_stub(). / debate:run_stub().
```

## Pre-push checklist

`fmt --check` -> `xref` -> `dialyzer` -> `eunit` -> `ct`, all green.

## Conventions

- OTP 29+. The `~"..."` sigil for binaries, never `<<"...">>`.
- No `lists:foldl/foldr` - list comprehensions + `maps:from_list`, or explicit
  named recursion.
- Logging (where present): `?LOG_*` macros with `#{...}` map reports, never
  `logger:info/error` format strings.
- Docs: OTP `-moduledoc` / `-doc`; ex_doc guides under `docs/`.
- `{vsn, "git"}` in `.app.src` - the version derives from git tags, never
  hand-edited.

## Architecture

```
gakudan_sup
├── gakudan_registry        (ETS map of run_id -> pids)
└── gakudan_runs_sup        (simple_one_for_one)
    └── gakudan_run_sup     (per run; one_for_all)
        ├── gakudan_blackboard   (gen_server + ETS)
        └── gakudan_run_statem   (gen_statem orchestrator)
```

A "turn" runs in a short-lived worker spawned from the run statem, so
cancellation and crash isolation work without blocking the statem. Full map:
[docs/architecture.md](docs/architecture.md).

## Extension points (behaviours)

`gakudan_agent`, `gakudan_router`, `gakudan_tool`, `gakudan_llm`,
`gakudan_validator`, `gakudan_context`, `gakudan_checkpointer`,
`gakudan_audit`, `gakudan_guardrail`, `gakudan_budget`. Implement one in your
own module and pass it via run config; the built-ins are the reference
implementations.

Composable LLM backends (`gakudan_llm_fallback`, `gakudan_llm_retry`) and the
extra routers (`gakudan_router_loop`, `gakudan_router_auto`) are themselves
built on these behaviours - resilience and control-flow shapes live as
backends/routers, never as warps to core. Per-request generation options
(`tool_choice`, `response_format`, `max_tokens`, `temperature`,
`stop_sequences`, plus a `validator`) ride on an agent's optional
`request_options/0` callback; structured output is validated and exposed on
the blackboard under `structured_output`. A `context` transform compacts the
transcript before each LLM call. Tool calls within a turn run in parallel on
monitored workers, preserving block order. `start_run/1` accepts
`fork_from => {RunId, StepId}` to branch from a checkpoint.

## Persistence + audit backends

gakudan core ships no database driver. The kura-backed checkpointer and audit
sink need a kura backend: add **kura_postgres** (production) or **kura_sqlite**
(local) and configure a `kura_repo`. The schema ships as kura migrations under
`migrations/`. See the Persistence and Audit sections of the README.

## Decisions live in ADRs

Before changing a behaviour or a contract, read [docs/adr/](docs/adr/) - it is
the record of *why*. Write a new ADR (Nygard format) for any new behaviour,
backend, or contract change. Index: [docs/adr/README.md](docs/adr/README.md).

## Tests

Unit suites use in-memory ETS stubs. `gakudan_kura_SUITE` exercises the real
kura + kura_postgres stack against Postgres and skips when no DB is reachable.
`test/agent_a_mod.erl` and `test/agent_b_mod.erl` are minimal fixtures - do not
add behaviour to them.

## Git and PRs

Conventional commits (`feat:`, `fix:`, `chore:`, `docs:`, `test:`, `refactor:`).
Always open a PR - never push to `main`. Every merge to `main` tags a release,
so keep each PR coherent.
