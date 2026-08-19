# 24. Per-run agent options, and total config redaction

Date: 2026-08-19

## Status

Accepted

## Context

`gakudan:run_config()` has always accepted `agent_spec() :: module() | {module(),
Opts :: map()}`. The opts half was parsed, stored in the run's agent map, and
carried through `format_status/1` redaction - and then discarded unread at
`gakudan_run_statem.erl:435`:

```erlang
{AgentMod, _AgentOpts} = maps:get(AgentId, Agents),
```

So the public type promised per-run agent configuration that the runtime did not
deliver. `gakudan_agent:tools/0` is arity-0, which means an agent module's tool
list is fixed at compile time. Two runs of the same agent module cannot be given
different tool scopes.

That is only cosmetic until a tool needs to be scoped per tenant. A memory tool
needs a namespace; an MCP tool needs a client name (ADR 0006); a tenant-specific
allow-list needs the tenant. With `tools/0` the only way to vary them is to let
the model supply the scope in the tool's `Input` - which means a model that can
choose its own namespace can read another tenant's data. That is the same shape
as the caller-supplied-key cross-tenant read fixed in #66, and it should not be
the only path available.

Separately, `gakudan_checkpointer:redact_config/1` special-cased exactly one key:

```erlang
redact_config(#{llm := Spec} = Config) -> Config#{llm => redact_spec(Spec)};
```

Every other key was persisted verbatim. A credential under `guardrails`,
`audit`, `agents`, `router`, or any key invented later was written unredacted
into `gakudan_runs.data` - the #66 defect re-created under every future key.

## Decision

**Add an optional `gakudan_agent:tools/1`** receiving the agent's opts from the
run config, resolved at runtime by `gakudan_agent:tools/2`. Both `tools/0` and
`tools/1` are optional; `tools/1` wins when exported, `tools/0` is used
otherwise, and an agent that declares neither has no tools.

This mirrors exactly what ADR 0006 did to `gakudan_tool`, widening `spec/0` to
`spec/1` and `run/1` to `run/2` with `resolve_one/1` picking the pair at
runtime. The precedent and the mechanism are the same.

**Thread the agent opts** from `gakudan_run_statem` into `gakudan_turn` through
the existing per-turn context map, which already carries `audit`, `actor` and
`context`. No arity change to `gakudan_turn:run/11`.

**Make `redact_config/1` total.** `redact_nested/1` is already total over maps,
tuples and lists and strips the credential keys at every level, so
`redact_config(Config) -> redact_nested(Config)` covers every key including ones
nobody has invented.

## Consequences

- Scoping is host-supplied. It comes from the run config, which the host writes,
  never from LLM-supplied tool input. gakudan does not construct or default a
  scope, because a default shared scope is an isolation bug shipped as a default.
- This is a primitive, not a feature. It closes the tenancy gap for memory, for
  per-tenant MCP clients, for per-run API scopes and for tool allow-lists, with
  no surface specific to any of them. A `gakudan_memory` behaviour was considered
  and not added: ADR 0019 already names embed-and-retrieve as a `gakudan_context`
  policy, so the read half of memory needs no new behaviour, and the write half
  is reachable as a tool. Eleven behaviours would have bought what one optional
  callback buys.
- `tools/0` becoming optional removes boilerplate: agents with no tools no longer
  need `tools() -> [].`
- Total redaction is a behaviour change. A key literally named `api_key`,
  `access_token` or `token_fun` is now stripped from any config map, not only
  from the `llm` spec. That is the safe direction, and a host that wants such a
  value to survive a checkpoint must resolve it at runtime from a name, as
  ADR 0006 does for MCP clients, rather than embed it in the config.
- Two `redact_spec/1` clauses became unreachable and were removed. Dialyzer
  caught it; eqwalizer errors dropped by six across the two modules.

## What this does not do

- It does not redact `save_step/2`. Step records still hold the full request,
  including any content a context transform injected. A host recalling sensitive
  material into a turn should expect it in `gakudan_steps.data`.
- It does not give agents a post-turn write hook. ADR 0019 keeps `compact/3` a
  pure shaping step, so automatic remember-after-turn remains unavailable by
  design; the tool path covers it, and the model chooses what is worth keeping.
