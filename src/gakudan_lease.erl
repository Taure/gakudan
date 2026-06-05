-module(gakudan_lease).
-moduledoc """
Run-leasing configuration for horizontal scale-out (ADR 0023).

Reads the `lease` map from the `gakudan` application env. Leasing is off by
default; a single-node deployment needs no configuration and behaves exactly
as before.

```erlang
{lease, #{
    enabled => true,
    owner_id => ~"node-a",        % default: node() + a per-boot token
    ttl_ms => 30000,
    renew_interval_ms => 10000,
    claim_interval_ms => 15000,
    claim_batch => 50
}}
```

`owner_id` identifies this node across the shared store. Configure a stable
value per node for production; the default combines `node()` with a per-boot
token, which is fine when nodes have distinct names.
""".

-export([
    enabled/0,
    config/0,
    owner_id/0,
    ttl_ms/0,
    renew_interval_ms/0,
    claim_interval_ms/0,
    claim_batch/0
]).

-define(DEFAULT_TTL_MS, 30000).
-define(DEFAULT_RENEW_MS, 10000).
-define(DEFAULT_CLAIM_MS, 15000).
-define(DEFAULT_BATCH, 50).

-spec enabled() -> boolean().
enabled() -> maps:get(enabled, config(), false) =:= true.

-spec config() -> map().
config() -> application:get_env(gakudan, lease, #{}).

-spec ttl_ms() -> pos_integer().
ttl_ms() -> maps:get(ttl_ms, config(), ?DEFAULT_TTL_MS).

-spec renew_interval_ms() -> pos_integer().
renew_interval_ms() -> maps:get(renew_interval_ms, config(), ?DEFAULT_RENEW_MS).

-spec claim_interval_ms() -> pos_integer().
claim_interval_ms() -> maps:get(claim_interval_ms, config(), ?DEFAULT_CLAIM_MS).

-spec claim_batch() -> pos_integer().
claim_batch() -> maps:get(claim_batch, config(), ?DEFAULT_BATCH).

-spec owner_id() -> gakudan_checkpointer:owner_id().
owner_id() ->
    case persistent_term:get({?MODULE, owner_id}, undefined) of
        undefined ->
            Id = configured_or_default(),
            persistent_term:put({?MODULE, owner_id}, Id),
            Id;
        Id ->
            Id
    end.

configured_or_default() ->
    case maps:get(owner_id, config(), undefined) of
        Bin when is_binary(Bin) -> Bin;
        _ -> default_owner_id()
    end.

default_owner_id() ->
    Node = atom_to_binary(node(), utf8),
    Token = integer_to_binary(erlang:unique_integer([positive])),
    <<Node/binary, "-", Token/binary>>.
