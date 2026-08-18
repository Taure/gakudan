# 3. Checkpointer behaviour and snapshot shape

Date: 2026-05-25

## Status

Accepted (v0.2).

## Context

`gakudan` v0.1 keeps every per-run process in-memory. When the BEAM stops
for any reason (deploy, crash, host restart) every in-flight run is lost.
That is fine for a stub-driven demo but disqualifies the library from any
production deployment where a multi-minute or multi-hour collaboration
must survive a restart.

The competing landscape made persistence table stakes between v0.1 and
v0.2:

- LangGraph 1.0 ships four checkpointers (in-memory, SQLite, Postgres,
  Redis) and treats durable execution as a first-class feature.
- Microsoft Agent Framework 1.0 ships with Azure-managed checkpointing.
- Jido on the BEAM ships `Hibernate / thaw / InstanceManager` for the
  same purpose.

Without persistence, gakudan loses every serious BEAM-vs-Jido comparison
in 2026.

A separate driver is that we already lean on `kura` (2.3 multi-backend:
`kura_postgres`, `kura_sqlite`, future `kura_mysql`) for every other
persistence concern in the surrounding ecosystem (`asobi`, `triagebot`,
`gakudan_tickets`). Building on `kura` keeps gakudan stack-aligned, gets
us SQLite-for-test and Postgres-for-prod for free, and avoids a parallel
ORM layer in gakudan core.

The contract that gets locked in this ADR is the **behaviour**. The
default impl is one consequence of the contract, not the contract itself.

## Decision

### `gakudan_checkpointer` behaviour

A new behaviour module declares the persistence seam:

```erlang
-module(gakudan_checkpointer).

-type run_snapshot() :: #{
    run_id        := gakudan:run_id(),
    status        := pending | running | idle | awaiting_human | completed | {error, term()},
    config        := gakudan:run_config(),
    last_step     := non_neg_integer(),
    blackboard    := [gakudan_blackboard:entry()],
    kv            := #{atom() => term()},
    router_state  := term(),
    statem_state  := atom(),
    turn          := non_neg_integer(),
    updated_at    := integer()
}.

-type step_record() :: #{
    run_id     := gakudan:run_id(),
    step_id    := binary(),
    agent_id   := atom(),
    turn       := non_neg_integer(),
    request    := term(),
    response   := term(),
    usage      := gakudan_llm:usage(),
    inserted_at := integer()
}.

-callback init(Opts :: map()) -> {ok, state()} | {error, term()}.
-callback save_snapshot(state(), run_snapshot()) -> ok | {error, term()}.
-callback load_snapshot(state(), gakudan:run_id()) ->
    {ok, run_snapshot()} | {error, not_found | term()}.
-callback list_active(state()) -> {ok, [gakudan:run_id()]} | {error, term()}.
-callback delete_run(state(), gakudan:run_id()) -> ok | {error, term()}.
-callback save_step(state(), step_record()) -> ok | {error, term()}.
-callback load_step(state(), gakudan:run_id(), StepId :: binary()) ->
    {ok, step_record()} | {error, not_found}.
```

`state()` is the checkpointer's private handle (a kura repo name, a file
path, whatever it needs). The library never inspects it.

Two collections live in this contract:

1. **Snapshots** are the resumable view of a run at a moment in time.
   Overwritten in place every meaningful state transition.
2. **Step records** are append-only per LLM call. They exist for
   idempotency on resume (ADR 0004) and for offline audit.

### Default impl: `gakudan_checkpointer_kura`

Ships in core. Uses two `kura_schema`s, `gakudan_run` and `gakudan_step`,
mapping 1:1 to the types above. Snapshot blob fields (`blackboard`,
`kv`, `router_state`, `config`) are persisted as `term_to_binary` in a
single `BYTEA` (Postgres) / `BLOB` (SQLite) column. We deliberately do
**not** normalise blackboard entries into a separate table; the
blackboard is opaque to the persistence layer, and the cost of one
extra `term_to_binary` per checkpoint is negligible compared to the
LLM round-trip we just made.

Migrations live under `priv/migrations/` and ship with the library;
host apps run `rebar3 kura compile` against their configured repo.

### What gets persisted

Per snapshot, in `run_snapshot()`:

- `run_id` - primary key.
- `status` - coarse lifecycle: pending → running ↔ idle ↔ awaiting_human → completed.
  Drives resumer behaviour.
- `config` - full `gakudan:run_config()` map as supplied to `start_run/1`,
  minus credentials. The LLM `Opts` portion **is** persisted, with the
  credential-bearing keys removed: `api_key`, `access_token` and `token_fun`,
  stripped at every level of a composed backend spec. The rest of the config
  has to survive, because `gakudan_runs_resumer` and `gakudan_lease_server`
  rebuild an unattended run from it and there is no host present to re-supply
  anything. The backends re-resolve the stripped keys from the environment
  (`ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_VERTEX_TOKEN`) on resume.
- `last_step` - monotonically-increasing step counter for idempotency.
- `blackboard` - entries list and KV map captured by snapshotting the
  blackboard process.
- `router_state` - opaque term returned by `RouterMod:next/2`.
- `statem_state` - name of the current gen_statem state.
- `turn` - current turn number.
- `updated_at` - `erlang:system_time(millisecond)`.

Per step record:

- `run_id`, `step_id` - composite key. `step_id` is
  `<<TurnNo:64, AgentId:binary>>` (BLAKE2b hash of the concatenation in
  practice; see ADR 0004 for the exact derivation).
- `request`, `response` - `term_to_binary` of the inbound LLM request
  and response normalised maps.
- `usage` - token counts as a queryable map column for cost reporting.
- `inserted_at` - `erlang:system_time(millisecond)`.

### What we deliberately do not persist

- **Credentials anywhere they would be logged.** The run's real `llm` spec
  lives in `gakudan_registry` and never enters the config that travels into
  supervisor child specs or snapshots, because a supervisor crash report
  prints `mfargs` verbatim at ERROR level. The statem's `#data` holds only
  redacted opts and the live spec is fetched inside the turn worker at
  dispatch, so the credential never enters gen_statem state - which also
  covers `sys:get_state/1`, a surface no `format_status/1` callback can
  intercept.
- **Credentials in LLM `Opts`**. `api_key`, `access_token` and `token_fun`
  are stripped by `gakudan_checkpointer:redact_config/1` on the way to
  storage, recursively through maps, tuples and lists so neither a
  `gakudan_llm_fallback` / `gakudan_llm_retry` composition nor a consumer's
  own composed backend can smuggle one through. Note `base_url` is deliberately NOT stripped: it is required
  to route a resumed run through the same gateway. A `base_url` carrying an
  embedded token is therefore persisted - put the credential in `api_key`,
  not in the URL.
- **Turn-worker process state**. Turns are short-lived, idempotent, and
  re-run on resume from the last completed step. Persisting an
  in-progress turn is more complex than re-running it.
- **Subscriber refs on the blackboard**. Subscribers reattach after
  resume; resumed runs replay the snapshot's blackboard entries to
  fresh subscribers via the existing pub/sub channel.
- **Telemetry handler state**. Handlers are global; they reattach to
  resumed runs automatically.

### Configuration

`start_run/1` gains an optional `checkpointer` key:

```erlang
gakudan:start_run(#{
    agents       => [...],
    router       => {...},
    llm          => {...},
    checkpointer => {gakudan_checkpointer_kura, #{repo => my_repo}}
}).
```

Default: no checkpointer (legacy v0.1 behaviour, in-memory only). When
absent, `gakudan_runs_resumer` is a no-op and no rows are written.

Applications that want global persistence set
`{gakudan, [{default_checkpointer, {Mod, Opts}}]}` in `sys.config`;
runs that omit the key fall back to that default.

### Stability

The behaviour callbacks, the `run_snapshot()` and `step_record()` map
shapes, and the public `checkpointer` config key are stable from v0.2
onward and follow semver. Adding optional snapshot or step fields is a
minor bump. Removing or renaming fields, or changing callback arities,
is a major bump.

The on-disk layout of `gakudan_checkpointer_kura` is **not** public API.
It can change between minor releases as long as migrations carry
existing data forward.

## Consequences

**Positive.**

- Runs survive BEAM restarts.
- Step records double as an audit log and a cost ledger; queries like
  "what did agent X cost across all runs this week" become single
  `kura_query` calls.
- The behaviour seam means anyone can implement Mnesia, ETS+DETS,
  Redis, or S3 backends without touching gakudan core.
- The default impl works on Postgres (production) and SQLite (dev/tests
  with `:memory:`) with no library changes, courtesy of kura 2.3
  multi-backend.
- `gakudan_metrics` gets two new histograms
  (`gakudan.checkpoint.save.duration`,
  `gakudan.checkpoint.load.duration`) and one counter
  (`gakudan.checkpoint.save.bytes`) in lockstep.

**Negative.**

- One new mandatory transitive dep: `kura` (and a host-chosen backend
  package, `kura_postgres` or `kura_sqlite`). Gakudan stays small
  (`telemetry` + `kura` core); host apps opt into a driver.
- `term_to_binary` snapshot blobs are not human-readable in `psql` /
  `sqlite3`. Inspection requires a small `gakudan_checkpointer:inspect/2`
  helper or piping through `erl -eval`. We accept this in v0.2;
  human-readable snapshots are a v0.3 nice-to-have.
- Re-running the last incomplete turn on resume can re-execute tool
  side effects. The mitigation is the step-id idempotency rule in
  ADR 0004 (LLM calls are deduped; tool authors must make their tools
  idempotent or accept replay).
- Schema-locked snapshot shape means adding a load-bearing field is a
  migration. We mitigate by carrying the entire run-config as opaque
  `term_to_binary` rather than normalising it; only the fields we want
  to query (status, last_step, updated_at) get their own columns.