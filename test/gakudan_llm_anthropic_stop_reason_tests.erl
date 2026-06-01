-module(gakudan_llm_anthropic_stop_reason_tests).
-include_lib("eunit/include/eunit.hrl").

known_stop_reasons_map_test() ->
    Cases = [
        {~"end_turn", end_turn},
        {~"max_tokens", max_tokens},
        {~"stop_sequence", stop_sequence},
        {~"tool_use", tool_use},
        {~"pause_turn", pause_turn},
        {~"refusal", refusal}
    ],
    [
        ?assertEqual(Expected, parse_stop(Reason))
     || {Reason, Expected} <- Cases
    ].

unknown_stop_reason_collapses_to_fixed_atom_test() ->
    Novel = ~"some_brand_new_reason_xyz_42",
    %% Sanity: the input must not already be an existing atom, otherwise the
    %% test would not prove that we avoid minting one.
    ?assertError(badarg, binary_to_existing_atom(Novel, utf8)),
    ?assertEqual(unknown, parse_stop(Novel)),
    %% And crucially no atom was derived from the input.
    ?assertError(badarg, binary_to_existing_atom(Novel, utf8)).

empty_stop_reason_does_not_crash_test() ->
    ?assertEqual(unknown, parse_stop(~"")).

parse_stop(Reason) ->
    Body = iolist_to_binary(
        json:encode(#{
            ~"stop_reason" => Reason,
            ~"content" => [#{~"type" => ~"text", ~"text" => ~"hi"}]
        })
    ),
    {ok, #{stop_reason := SR}} = gakudan_llm_anthropic:parse_response(Body),
    SR.
