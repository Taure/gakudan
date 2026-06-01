# Architecture

`gakudan` is a small OTP library built around a handful of pluggable concepts.
The core five are below; checkpointers, audit sinks, guardrails, and budgets
are the same shape - a behaviour with a built-in reference implementation.

## Concepts

### Run

A *run* is one collaboration session between two or more agents. Each run is
its own supervision tree, identified by a `run_id` binary. When the run
terminates (normally, by `gakudan:stop/1`, or by the max-turns guard), its
entire subtree is torn down.

### Agent

An *agent* is a callback module implementing `gakudan_agent`. It declares an
id, a system prompt, a list of tools, and a model. Agents do not have their
own gen_statem; the run state machine drives turns directly using the agent's
callbacks.

### Router

A *router* is a behaviour module that decides whose turn is next given the
current transcript. Routers are stateful and the state is threaded through
the run state machine. The library ships four:

- `gakudan_router_round_robin` - cycles through agents, useful for
  brainstorming or alternating critique/edit loops.
- `gakudan_router_handoff` - one agent runs at a time and hands off by
  emitting an `@<agent>` token. Useful for "specialist passing the baton".
- `gakudan_router_manager` - a manager agent picks the next worker each
  round. Useful for team-lead/specialist topologies.
- `gakudan_router_fanout` - runs every agent concurrently, one parallel
  round at a time. Useful for ensemble / poll / map topologies.

### Blackboard

A *blackboard* is a gen_server owning two ETS tables: an append-only ordered
log of entries (the transcript) and a small KV scratchpad for runtime state.
Subscribers receive `{gakudan_blackboard, RunId, {entry_added, Entry}}`
messages, suitable for a dashboard or audit log.

### Tool

A *tool* is a callback module implementing `gakudan_tool`. It exposes a JSON
schema to the LLM via `spec/0` and runs synchronously via `run/1`. Tools are
dispatched in-process during a turn. Long-running or expensive tools should
be wrapped behind an async dispatcher in your own code.

### LLM backend

An *LLM backend* implements `gakudan_llm`. The library ships:

- `gakudan_llm_anthropic` - Anthropic Messages API adapter.
- `gakudan_llm_gemini` - Google Gemini adapter.
- `gakudan_llm_vertex` - Google Vertex AI adapter.
- `gakudan_llm_stub` - deterministic stub for tests and offline demos.

Backends implement `complete/2`; those that also implement `stream_call/3`
deliver token-level deltas, and the rest fall back to a single delta.

## Process tree

```
gakudan_sup (one_for_one)
├── gakudan_registry        gen_server, owns ETS run_id -> pids
└── gakudan_runs_sup        simple_one_for_one of gakudan_run_sup
    └── gakudan_run_sup     one_for_all per run
        ├── blackboard      gen_server
        └── run_statem      gen_statem orchestrator
            └── turn worker spawn_monitor'd per turn
```

The registry holds pids so the public API can address a run by id.
Self-cleanup happens via DOWN monitors when the run_sup dies.

## Lifecycle

1. `gakudan:start_run/1` validates config and asks `gakudan_runs_sup` to
   start a new `gakudan_run_sup`.
2. The run_sup starts the blackboard and the run state machine.
3. The run state machine starts in state `initialising`; it processes one
   internal `finish_init` event that resolves its blackboard sibling pid
   and registers in `gakudan_registry`. Then it transitions to `idle`.
4. `gakudan:send/2` casts a user message into the run, transitioning to
   `running` and spawning a turn worker.
5. The turn worker executes one agent turn (possibly with several tool
   loops), then signals `turn_complete`.
6. The run statem asks the router for the next agent. If none, transitions
   back to `idle`. If max_turns is hit, also goes idle.
7. `gakudan:stop/1` terminates the run_sup; the registry cleans up.

## Evals

`gakudan_eval` runs a single agent collaboration against `gakudan_llm_stub`
with a scripted response queue, collects the blackboard transcript and the
telemetry event stream, and runs declarative expectations over both. See
[ADR 0002](adr/0002-eval-harness.md) for the case format and the matcher
vocabulary. Stub-driven so it is deterministic, offline, and free.

## Telemetry

Every interesting boundary in a run is wrapped in a `:telemetry` event:

- `[gakudan, run, start | stop]` - one pair per run, with `turns` count on stop.
- `[gakudan, turn, start | stop]` - one pair per agent turn, with `outcome`
  (`ok | failed`) and `duration` on stop.
- `[gakudan, llm, request, *]` - span around each LLM call, with `tokens_in`
  and `tokens_out` in stop measurements.
- `[gakudan, tool, run, *]` - span around each tool dispatch.
- `[gakudan, router, decide, *]` - span around each router decision, with
  `decision` (`{next, AgentId} | done`) on stop.

These events are stable public API from v0.1 onward. See
[ADR 0001](adr/0001-telemetry-events.md) for the full schema. Downstream
metric exporters, audit pipelines, and eval harnesses subscribe to these
events without coupling to gakudan internals.

## What this library is not

- Not a workflow engine. There is no DAG. Persistence is opt-in via a
  checkpointer; without one, a run is in-memory only.
- Not a multi-node coordinator. Single-node by design.
- Not a UI. A companion `gakudan_liveboard` (Arizona) is planned.
- Not opinionated about which LLM you use. Bring your own backend module.
