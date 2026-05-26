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

verify_passes_on_intact_rows_test() ->
    Rows = [row(event()), row(event(#{type => run_stopped}))],
    ?assertEqual([], gakudan_audit_kura:tampered_rows(Rows)).

verify_flags_a_stale_hash_test() ->
    Good = row(event()),
    Tampered = (row(event()))#{id => ~"aud-2", event_hash => ~"deadbeef"},
    ?assertEqual([~"aud-2"], gakudan_audit_kura:tampered_rows([Good, Tampered])).

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

row(Event) ->
    #{
        id => ~"aud-1",
        data => term_to_binary(Event),
        event_hash => gakudan_audit_kura:event_hash(Event)
    }.
