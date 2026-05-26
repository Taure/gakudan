-module(gakudan_audit_kura_tests).
-include_lib("eunit/include/eunit.hrl").

event_hash_is_stable_test() ->
    Event = event(),
    ?assertEqual(
        gakudan_audit_kura:event_hash(Event),
        gakudan_audit_kura:event_hash(Event)
    ).

event_hash_changes_with_content_test() ->
    E1 = event(),
    E2 = E1#{detail => #{mode => human}},
    ?assertNotEqual(
        gakudan_audit_kura:event_hash(E1),
        gakudan_audit_kura:event_hash(E2)
    ).

intact_chain_passes_test() ->
    Rows = chain([event(), event(#{type => run_stopped})]),
    ?assertEqual([], gakudan_audit_kura:tampered_rows(Rows)).

edited_row_is_flagged_test() ->
    [R1, R2] = chain([event(), event(#{type => run_stopped})]),
    %% Rewrite R2's stored data but keep its hashes: content no longer matches.
    Tampered = R2#{data => term_to_binary(event(#{type => run_interrupted}))},
    ?assertEqual([id(R2)], gakudan_audit_kura:tampered_rows([R1, Tampered])).

deleted_row_is_flagged_test() ->
    [R1, _R2, R3] = chain([event(), event(#{type => run_resumed}), event(#{type => run_stopped})]),
    %% Drop the middle row: R3's prev_hash no longer matches R1's row_hash.
    ?assertEqual([id(R3)], gakudan_audit_kura:tampered_rows([R1, R3])).

chain_hash_links_prev_test() ->
    H = gakudan_audit_kura:event_hash(event()),
    ?assertNotEqual(
        gakudan_audit_kura:chain_hash(gakudan_audit_kura:genesis(), H),
        gakudan_audit_kura:chain_hash(~"other", H)
    ).

event() ->
    event(#{}).

event(Overrides) ->
    Base = #{
        type => run_started,
        run_id => ~"run-1",
        timestamp => 1,
        detail => #{mode => fresh}
    },
    maps:merge(Base, Overrides).

%% Build a valid chain of rows from a list of events, as the sink would.
chain(Events) ->
    chain(Events, gakudan_audit_kura:genesis(), 1, []).

chain([], _Prev, _N, Acc) ->
    lists:reverse(Acc);
chain([Event | Rest], Prev, N, Acc) ->
    EventHash = gakudan_audit_kura:event_hash(Event),
    RowHash = gakudan_audit_kura:chain_hash(Prev, EventHash),
    Row = #{
        id => iolist_to_binary(io_lib:format("aud-~3..0b", [N])),
        data => term_to_binary(Event),
        event_hash => EventHash,
        prev_hash => Prev,
        row_hash => RowHash
    },
    chain(Rest, RowHash, N + 1, [Row | Acc]).

id(#{id := Id}) -> Id.
