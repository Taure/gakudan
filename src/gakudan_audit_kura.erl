-module(gakudan_audit_kura).
-moduledoc """
Default `gakudan_audit` sink backed by `kura`.

Works against any kura backend (`kura_postgres`, `kura_sqlite`). Each event
is one append-only row in the `gakudan_audit` table. `actor.id` and
`actor.tenant` are lifted into their own columns for direct querying; the
full event is stored as a `term_to_binary` blob, and `event_hash` is the
SHA-256 of the deterministically-encoded event for per-row tamper detection.

Configuration:

```erlang
audit => {gakudan_audit_kura, #{repo => my_repo, on_error => fail_closed}}
```

`my_repo` must be a `kura_repo` configured under the `kura` application env.
See [ADR 0012](docs/adr/0012-audit-logging.md).
""".

-behaviour(gakudan_audit).

-include_lib("kura/include/kura.hrl").

-export([init/1, record/2]).
-export([list/2, verify/2]).

-ifdef(TEST).
-export([event_hash/1, tampered_rows/1]).
-endif.

-export_type([state/0]).

-type state() :: #{repo := module()}.

-spec init(map()) -> {ok, state()} | {error, term()}.
init(#{repo := Repo}) when is_atom(Repo) ->
    {ok, #{repo => Repo}};
init(_) ->
    {error, {bad_config, missing_repo}}.

-spec record(state(), gakudan_audit:event()) -> ok | {error, term()}.
record(#{repo := Repo}, Event) ->
    #{type := Type, run_id := RunId, timestamp := Ts} = Event,
    Actor = maps:get(actor, Event, #{}),
    Required = #{
        id => new_id(Ts),
        run_id => RunId,
        type => atom_to_binary(Type),
        data => term_to_binary(Event),
        event_hash => event_hash(Event),
        inserted_at => system_time_datetime(Ts)
    },
    Changes = add_optional(Required, [
        {actor_id, opt_binary(maps:get(id, Actor, undefined))},
        {tenant, opt_binary(maps:get(tenant, Actor, undefined))},
        {agent_id, opt_agent(maps:get(agent_id, Event, undefined))},
        {turn, maps:get(turn, Event, undefined)}
    ]),
    Permitted = [id, run_id, type, actor_id, tenant, agent_id, turn, data, event_hash, inserted_at],
    CS = kura_changeset:cast(gakudan_audit_schema, #{}, Changes, Permitted),
    normalise(kura_repo_worker:insert(Repo, CS)).

-doc "All audit events for a run, oldest first.".
-spec list(state(), gakudan:run_id()) -> {ok, [gakudan_audit:event()]} | {error, term()}.
list(#{repo := Repo}, RunId) ->
    Q0 = kura_query:from(gakudan_audit_schema),
    Q1 = kura_query:where(Q0, {run_id, '=', RunId}),
    %% Ids are time-ordered (ms-prefixed), so id asc is chronological even
    %% when several events share a whole-second inserted_at.
    Q2 = kura_query:order_by(Q1, [{id, asc}]),
    case kura_repo_worker:all(Repo, Q2) of
        {ok, Rows} -> {ok, [binary_to_term(Blob) || #{data := Blob} <- Rows]};
        {error, _} = Err -> Err
    end.

-doc """
Recompute every stored row hash for a run and compare. Returns `ok` when all
rows are intact, or `{tampered, [Id]}` listing rows whose stored `event_hash`
no longer matches their `data`.
""".
-spec verify(state(), gakudan:run_id()) -> ok | {tampered, [binary()]} | {error, term()}.
verify(#{repo := Repo}, RunId) ->
    Q0 = kura_query:from(gakudan_audit_schema),
    Q1 = kura_query:where(Q0, {run_id, '=', RunId}),
    case kura_repo_worker:all(Repo, Q1) of
        {ok, Rows} ->
            case tampered_rows(Rows) of
                [] -> ok;
                Bad -> {tampered, Bad}
            end;
        {error, _} = Err ->
            Err
    end.

tampered_rows(Rows) ->
    [
        Id
     || #{id := Id, data := Blob, event_hash := Stored} <- Rows,
        event_hash(binary_to_term(Blob)) =/= Stored
    ].

add_optional(Changes, []) ->
    Changes;
add_optional(Changes, [{_Key, undefined} | Rest]) ->
    add_optional(Changes, Rest);
add_optional(Changes, [{Key, Value} | Rest]) ->
    add_optional(Changes#{Key => Value}, Rest).

opt_binary(B) when is_binary(B) -> B;
opt_binary(_) -> undefined.

opt_agent(Id) when is_atom(Id), Id =/= undefined -> atom_to_binary(Id);
opt_agent(_) -> undefined.

event_hash(Event) ->
    binary:encode_hex(crypto:hash(sha256, term_to_binary(Event, [deterministic])), lowercase).

new_id(Ts) ->
    Bytes = crypto:strong_rand_bytes(8),
    Hex = binary:encode_hex(Bytes, lowercase),
    iolist_to_binary(io_lib:format("aud-~13..0b-~s", [Ts, Hex])).

system_time_datetime(Ms) when is_integer(Ms) ->
    calendar:system_time_to_universal_time(Ms, millisecond).

normalise({ok, _}) -> ok;
normalise({error, _} = Err) -> Err.
