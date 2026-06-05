# 23. Run leasing for horizontal scale-out

Date: 2026-06-05

## Status

Accepted. Builds on [ADR 0003](0003-checkpointer-behaviour.md) (checkpointer
behaviour), [ADR 0004](0004-resume-interrupt-idempotency.md) (resume /
idempotency) and [ADR 0009](0009-tool-idempotency-supervised-resume.md)
(exactly-once tool replay).

This ADR refines the scope line "Out: multi-node distribution"; the **Scope**
section below records why leasing is not BEAM clustering. AGENTS.md is updated
to match.

## Context

gakudan is single-node by design: each run is a supervision tree that lives
entirely on one node, and `gakudan_runs_resumer` rehydrates a node's own
in-flight runs from the checkpointer on boot.

For companies running agents at scale the missing properties are horizontal
scale-out (capacity beyond one machine) and high availability (a node dying
must not strand its runs until that node restarts). Runs are already
recoverable state in a shared database, not state trapped in a node: the
`gakudan_checkpointer_kura` backend persists each run's snapshot and an
append-only step + tool-result ledger to Postgres. So the cloud-native pattern
is in reach - N shared-nothing gakudan nodes behind a load balancer, all
pointing at one Postgres - without clustering the BEAM.

The single blocker is ownership. `gakudan_runs_resumer` calls
`list_active/1` and resumes *every* active run. Two nodes sharing one Postgres
would both claim every run and double-execute it. We need exactly-once
ownership of each run across nodes, plus automatic hand-off when an owner dies.

## Decision

Add an **opt-in, database-coordinated lease** to the checkpointer contract. A
run is owned by at most one node at a time; ownership is a row-level claim in
the shared store, renewed by a heartbeat and reclaimed on expiry. Leasing is
off by default; single-node deployments are unchanged.

### Ownership model

- Each node has a stable `owner_id` (default `node()` plus a per-boot token, so
  a restarted VM never matches a pre-crash lease). Configurable.
- A run row gains two nullable columns: `owner_id` and `lease_expires_at`.
  Nullable keeps the migration a safe alter and leaves existing single-node
  rows claimable (NULL owner).

### Three operations, as optional checkpointer callbacks

`-optional_callbacks` on `gakudan_checkpointer`, so existing impls (the ETS
test double, single-node sqlite) keep working untouched:

```erlang
-callback claim_runs(state(), OwnerId :: binary(), Opts :: #{limit := pos_integer(),
                     lease_ttl_ms := pos_integer()}) ->
    {ok, [run_snapshot()]} | {error, term()}.

-callback renew_leases(state(), OwnerId :: binary(), [gakudan:run_id()],
                       LeaseTtlMs :: pos_integer()) ->
    {ok, Held :: [gakudan:run_id()]} | {error, term()}.

-callback release_run(state(), OwnerId :: binary(), gakudan:run_id()) ->
    ok | {error, term()}.
```

- **`claim_runs`** atomically selects active runs that are unowned or whose
  lease has expired, marks them owned by `OwnerId` until `now + ttl`, and
  returns their snapshots. On Postgres this is one
  `... WHERE status IN (...) AND (owner_id IS NULL OR lease_expires_at < now())
  ... FOR UPDATE SKIP LOCKED LIMIT N` then an update - `SKIP LOCKED` guarantees
  two nodes never grab the same row.
- **`renew_leases`** is the heartbeat: extend `lease_expires_at` for runs this
  node still owns, returning the set it actually still holds (so the caller
  learns immediately about leases it has lost).
- **`release_run`** clears ownership on graceful completion or clean shutdown.
  A crash needs no release - the lease simply expires and another node's claim
  sweep picks it up.

### Fencing (the correctness core)

A slow or partitioned owner whose lease expires can have its run claimed by a
second node while the first still believes it owns it. To prevent two live
copies diverging, **every snapshot write is ownership-conditional** when
leasing is on. `run_snapshot()` gains an optional `owner => binary()` field;
the kura backend writes with
`UPDATE ... WHERE run_id = ? AND owner_id = ? AND lease_expires_at > now()`.
Zero rows affected means the lease was lost, so `save_snapshot/2` returns the
new `{error, lease_lost}`. The run statem treats `lease_lost` as a fence: it
stops the run locally **without** marking it failed in the store (another node
owns it now) and emits telemetry.

This composes with the existing exactly-once guarantees: even a brief overlap
cannot double-fire side effects, because tool results are replayed from the
append-only ledger by step id (ADR 0009) and steps are idempotent (ADR 0004).
The layered defence is: lease for ownership, conditional write for fencing,
idempotent replay for exactly-once side effects.

### Where it runs

A new supervised singleton, `gakudan_lease_server`, started under
`gakudan_sup` only when leasing is configured. On a timer it (a) claims newly
available active runs and resumes each through the existing
`gakudan_runs_sup:resume_run/2` path, and (b) renews leases for the runs live
on this node, fencing any it has lost. `gakudan_runs_resumer`'s boot-time
resume becomes the first claim cycle; with leasing off it behaves exactly as
today.

### Configuration

```erlang
{lease, #{
    enabled => true,
    owner_id => ~"node-a",        % default: node() + boot token
    ttl_ms => 30000,
    renew_interval_ms => 10000,
    claim_interval_ms => 15000,
    claim_batch => 50
}}
```

### Schema + telemetry

- Two nullable columns on `gakudan_runs` (`owner_id`, `lease_expires_at`) plus
  an index on `(status, lease_expires_at)` for the claim query. The migration
  is generated with the kura build plugin (`rebar3 kura compile`), never
  hand-written, and `gakudan_run_schema` is updated to match.
- New telemetry: `[gakudan, lease, claimed | renewed | lost]` and
  `[gakudan, lease, renew, failed]`, with `count` / `run_id` / `owner_id`
  metadata. `gakudan_metrics` exports these in lockstep.

## Scope - why this is not multi-node distribution

The "Out: multi-node distribution" line excludes BEAM clustering. Leasing does
not cross it:

- No `net_kernel`, no distributed Erlang, no global process registry, no
  inter-node messaging, no run migration over BEAM distribution.
- Nodes stay shared-nothing. The only shared medium is the checkpointer
  database they already share.
- A run still lives entirely on one node at a time - single-node runtime
  semantics are preserved exactly; we only coordinate *which* node.

It also does not warp the library for one consumer: HA is a generic need for
any multi-node deployment, it rides the existing checkpointer behaviour as
optional callbacks, and the built-ins remain reference implementations. The
lease manager is one more opt-in supervised child; bring-your-own-everything
holds (implement the three callbacks on your own checkpointer to get leasing).

## Consequences

- **Horizontal scale-out and HA without clustering.** Run N nodes on one
  Postgres; load-balance new runs across them; a dead node's runs are
  reclaimed within one lease TTL. The simpler operational story enterprises
  prefer over distributed Erlang.
- **Back-compatible and opt-in.** Leasing off (the default) leaves every code
  path and every existing checkpointer impl unchanged. The new `owner`
  snapshot key and `{error, lease_lost}` return only appear when it is on.
- **Postgres-class backend required.** Claiming relies on `FOR UPDATE SKIP
  LOCKED`; `kura_postgres` provides it. sqlite is single-node, so leasing there
  is moot and stays unsupported.
- **Tuning is a trade-off.** Short TTL means fast failover but more renew
  traffic and a tighter fencing margin; long TTL means the opposite. Defaults
  (30s TTL, 10s renew) target seconds-scale failover.
- **New failure mode to handle: `lease_lost`.** The statem must fence cleanly
  on it. Covered by `gakudan_kura_SUITE` against real Postgres: two owners
  contending for one run, expiry-driven reclaim, and a fenced write returning
  `{error, lease_lost}`.
- **Residual.** Between an owner's death and lease expiry, that run makes no
  progress (bounded by TTL). Tighten TTL to shrink the window; eliminating it
  entirely would need push-based failure detection, which is out of scope.
