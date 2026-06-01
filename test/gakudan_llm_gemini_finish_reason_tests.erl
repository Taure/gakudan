-module(gakudan_llm_gemini_finish_reason_tests).
-include_lib("eunit/include/eunit.hrl").

known_finish_reasons_map_test() ->
    Cases = [
        {~"STOP", end_turn},
        {~"MAX_TOKENS", max_tokens},
        {~"TOOL_CALL", tool_use},
        {~"SAFETY", safety},
        {~"RECITATION", recitation},
        {~"OTHER", unknown},
        {~"FINISH_REASON_UNSPECIFIED", end_turn}
    ],
    [
        ?assertEqual(Expected, apply_finish(Reason))
     || {Reason, Expected} <- Cases
    ].

unknown_finish_reason_collapses_to_fixed_atom_test() ->
    Novel = ~"SOME_BRAND_NEW_REASON_XYZ_42",
    ?assertError(badarg, binary_to_existing_atom(Novel, utf8)),
    ?assertEqual(unknown, apply_finish(Novel)),
    ?assertError(badarg, binary_to_existing_atom(Novel, utf8)).

apply_finish(Reason) ->
    Chunk = #{
        ~"candidates" => [
            #{
                ~"content" => #{~"parts" => [#{~"text" => ~"hi"}]},
                ~"finishReason" => Reason
            }
        ]
    },
    Acc = gakudan_llm_gemini:apply_gemini_event(Chunk, gakudan_llm_gemini:fresh_stream_acc()),
    maps:get(stop_reason, Acc).
