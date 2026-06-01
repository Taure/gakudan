-module(gakudan_context_trim_tests).
-include_lib("eunit/include/eunit.hrl").

entry(Seq, Text) ->
    #{seq => Seq, role => user, content => Text, ts => Seq}.

ctx() ->
    #{run_id => ~"r", agent_id => a, turn => 1, model => ~"m"}.

under_budget_passes_through_test() ->
    Entries = [entry(1, ~"hello"), entry(2, ~"world")],
    ?assertEqual(Entries, gakudan_context_trim:compact(Entries, ctx(), #{max_tokens => 1000})).

drops_oldest_first_test() ->
    %% Each entry ~ 25 tokens (100 bytes / 4). Budget 30 keeps only newest.
    Big = list_to_binary(lists:duplicate(100, $x)),
    Entries = [entry(1, Big), entry(2, Big), entry(3, Big)],
    Kept = gakudan_context_trim:compact(Entries, ctx(), #{max_tokens => 30}),
    ?assertEqual([entry(3, Big)], Kept).

keep_first_is_pinned_test() ->
    Big = list_to_binary(lists:duplicate(100, $x)),
    Entries = [entry(1, Big), entry(2, Big), entry(3, Big)],
    %% Pin the oldest; budget then only fits one of the newer two.
    Kept = gakudan_context_trim:compact(Entries, ctx(), #{max_tokens => 55, keep_first => 1}),
    ?assertEqual([entry(1, Big), entry(3, Big)], Kept).

chronological_order_preserved_test() ->
    Entries = [entry(1, ~"a"), entry(2, ~"b"), entry(3, ~"c")],
    Kept = gakudan_context_trim:compact(Entries, ctx(), #{max_tokens => 1000}),
    Seqs = [maps:get(seq, E) || E <- Kept],
    ?assertEqual([1, 2, 3], Seqs).

estimate_tokens_test() ->
    ?assertEqual(0, gakudan_context_trim:estimate_tokens(~"")),
    ?assertEqual(1, gakudan_context_trim:estimate_tokens(~"abcd")),
    ?assertEqual(2, gakudan_context_trim:estimate_tokens(~"abcde")).

apply_undefined_passthrough_test() ->
    Entries = [entry(1, ~"x")],
    ?assertEqual(Entries, gakudan_context:apply(undefined, Entries, ctx())).

apply_ref_test() ->
    Big = list_to_binary(lists:duplicate(100, $x)),
    Entries = [entry(1, Big), entry(2, Big)],
    Ref = {gakudan_context_trim, #{max_tokens => 30}},
    ?assertEqual([entry(2, Big)], gakudan_context:apply(Ref, Entries, ctx())).
