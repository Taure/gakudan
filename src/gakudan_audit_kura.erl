-module(gakudan_audit_kura).
-moduledoc """
Default `gakudan_audit` sink backed by `kura`.

Works against any kura backend (`kura_postgres`, `kura_sqlite`). Each event
is one append-only row in the `gakudan_audit` table. `actor.id` and
`actor.tenant` are lifted into their own columns for direct querying; the
full event is stored as a `term_to_binary` blob.

Rows are **hash-chained per run** for tamper-evidence: `event_hash` is the
SHA-256 of the deterministically-encoded event (detects row edits), and
`row_hash = sha256(prev_hash <> event_hash)` links each row to the previous
one in the run, so an edited, deleted, or mid-chain-inserted row breaks the
chain. (A row forged onto the *tail* after the last legitimate one has no
successor to expose it; detecting that needs an external length/tail anchor,
which this sink does not keep.) Writes run
inside a transaction that locks the run's latest row (`FOR UPDATE`), so a
fanout's concurrent guardrail events chain in a well-defined order; the
genesis event (`run_started`) is always written first by the run statem, so
there is always a row to lock by the time concurrent writes occur. `verify/2`
walks the chain.

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
-export([event_hash/1, chain_hash/2, tampered_rows/1, genesis/0]).
-endif.

-export_type([state/0]).

-type state() :: #{repo := module()}.

-spec init(map()) -> {ok, state()} | {error, term()}.
init(#{repo := Repo}) when is_atom(Repo) ->
    {ok, #{repo => Repo}};
init(_) ->
    {error, {bad_config, missing_repo}}.

-spec record(state(), gakudan_audit:event()) -> ok | {error, term()}.
%% kura_driver_minato raises `transaction_rolled_back` out of transaction/2
%% when COMMIT reports a rollback, so a bare case/2 lets that escape past this
%% spec and past the caller's on_error policy. Catch it here: a DB blip on an
%% audit or snapshot write must be a value the policy layer can act on, not a
%% crash in the run statem.
record(#{repo := Repo}, Event) ->
    Fun = fun() -> insert_chained(Repo, Event) end,
    try kura_repo_worker:transaction(Repo, Fun) of
        ok -> ok;
        {ok, _} -> ok;
        {error, _} = Err -> Err;
        Other -> {error, Other}
    catch
        Class:Reason -> {error, {transaction_failed, Class, Reason}}
    end.

insert_chained(Repo, Event) ->
    #{type := Type, run_id := RunId, timestamp := Ts} = Event,
    case latest_row_hash(Repo, RunId) of
        {ok, Prev} ->
            Actor = maps:get(actor, Event, #{}),
            EventHash = event_hash(Event),
            Required = #{
                id => new_id(Ts),
                run_id => RunId,
                type => atom_to_binary(Type),
                data => term_to_binary(Event),
                event_hash => EventHash,
                prev_hash => Prev,
                row_hash => chain_hash(Prev, EventHash),
                inserted_at => system_time_datetime(Ts)
            },
            Changes = add_optional(Required, [
                {actor_id, opt_binary(maps:get(id, Actor, undefined))},
                {tenant, opt_binary(maps:get(tenant, Actor, undefined))},
                {agent_id, opt_agent(maps:get(agent_id, Event, undefined))},
                {turn, maps:get(turn, Event, undefined)}
            ]),
            CS = kura_changeset:cast(gakudan_audit_schema, #{}, Changes, [
                id,
                run_id,
                type,
                actor_id,
                tenant,
                agent_id,
                turn,
                data,
                event_hash,
                prev_hash,
                row_hash,
                inserted_at
            ]),
            normalise(kura_repo_worker:insert(Repo, CS));
        {error, _} = Err ->
            Err
    end.

%% The run's latest row, locked FOR UPDATE so concurrent fanout writes chain
%% in order. The lock is a no-op on SQLite, which serialises writers anyway.
latest_row_hash(Repo, RunId) ->
    Q0 = kura_query:from(gakudan_audit_schema),
    Q1 = kura_query:where(Q0, {run_id, '=', RunId}),
    Q2 = kura_query:order_by(Q1, [{id, desc}]),
    Q3 = kura_query:limit(Q2, 1),
    Q4 = kura_query:lock(Q3, ~"FOR UPDATE"),
    case kura_repo_worker:all(Repo, Q4) of
        {ok, [#{row_hash := H} | _]} -> {ok, H};
        {ok, []} -> {ok, genesis()};
        {error, _} = Err -> Err
    end.

-doc "All audit events for a run, oldest first.".
-spec list(state(), gakudan:run_id()) -> {ok, [gakudan_audit:event()]} | {error, term()}.
list(#{repo := Repo}, RunId) ->
    case ordered_rows(Repo, RunId) of
        {ok, Rows} -> {ok, [binary_to_term(Blob) || #{data := Blob} <- Rows]};
        {error, _} = Err -> Err
    end.

-doc """
Walk a run's hash chain and report tampering. Returns `ok` when every row is
intact, or `{tampered, [Id]}` listing rows whose content hash, chain link, or
row hash no longer matches - which covers row edits, deletions, and
insertions.
""".
-spec verify(state(), gakudan:run_id()) -> ok | {tampered, [binary()]} | {error, term()}.
verify(#{repo := Repo}, RunId) ->
    case ordered_rows(Repo, RunId) of
        {ok, Rows} ->
            case tampered_rows(Rows) of
                [] -> ok;
                Bad -> {tampered, Bad}
            end;
        {error, _} = Err ->
            Err
    end.

ordered_rows(Repo, RunId) ->
    Q0 = kura_query:from(gakudan_audit_schema),
    Q1 = kura_query:where(Q0, {run_id, '=', RunId}),
    %% Ids are time-ordered (ms-prefixed), so id asc is chain order.
    Q2 = kura_query:order_by(Q1, [{id, asc}]),
    kura_repo_worker:all(Repo, Q2).

%% Rows must be in chain order (id asc). Chaining forward with each row's
%% *stored* row_hash means a single edited/deleted/inserted row is flagged
%% without cascading false positives onto its successors.
tampered_rows(Rows) ->
    check_chain(Rows, genesis(), []).

check_chain([], _Prev, Bad) ->
    lists:reverse(Bad);
check_chain([Row | Rest], Prev, Bad) ->
    #{
        id := Id,
        data := Blob,
        event_hash := StoredEvent,
        prev_hash := StoredPrev,
        row_hash := StoredRow
    } = Row,
    EventHash = event_hash(binary_to_term(Blob)),
    Intact =
        StoredEvent =:= EventHash andalso
            StoredPrev =:= Prev andalso
            StoredRow =:= chain_hash(StoredPrev, EventHash),
    case Intact of
        true -> check_chain(Rest, StoredRow, Bad);
        false -> check_chain(Rest, StoredRow, [Id | Bad])
    end.

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

genesis() -> ~"genesis".

event_hash(Event) ->
    binary:encode_hex(crypto:hash(sha256, term_to_binary(Event, [deterministic])), lowercase).

chain_hash(Prev, EventHash) ->
    binary:encode_hex(crypto:hash(sha256, <<Prev/binary, EventHash/binary>>), lowercase).

new_id(Ts) ->
    Bytes = crypto:strong_rand_bytes(8),
    Hex = binary:encode_hex(Bytes, lowercase),
    iolist_to_binary(io_lib:format("aud-~13..0b-~s", [Ts, Hex])).

system_time_datetime(Ms) when is_integer(Ms) ->
    calendar:system_time_to_universal_time(Ms, millisecond).

normalise({ok, _}) -> ok;
normalise({error, _} = Err) -> Err.
