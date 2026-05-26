-module(gakudan_budget_limit_tests).
-include_lib("eunit/include/eunit.hrl").

no_caps_allows_test() ->
    ?assertEqual(allow, check(usage(#{total_tokens => 999999}), #{})).

under_limit_allows_test() ->
    ?assertEqual(allow, check(usage(#{total_tokens => 100}), #{max_tokens => 1000})).

max_tokens_denies_at_limit_test() ->
    ?assertEqual(
        {deny, {max_tokens, 100}}, check(usage(#{total_tokens => 100}), #{max_tokens => 100})
    ).

max_llm_calls_denies_test() ->
    ?assertEqual(
        {deny, {max_llm_calls, 3}},
        check(usage(#{llm_calls => 4}), #{max_llm_calls => 3})
    ).

input_and_output_caps_test() ->
    ?assertEqual(
        {deny, {max_output_tokens, 50}},
        check(usage(#{tokens_in => 10, tokens_out => 60}), #{max_output_tokens => 50})
    ).

first_breached_cap_wins_test() ->
    %% max_tokens is checked before max_llm_calls.
    Usage = usage(#{total_tokens => 200, llm_calls => 10}),
    ?assertEqual({deny, {max_tokens, 100}}, check(Usage, #{max_tokens => 100, max_llm_calls => 5})).

check(Usage, Opts) ->
    gakudan_budget_limit:check(Usage, #{run_id => ~"r", actor => #{}, opts => Opts}).

usage(Overrides) ->
    Base = #{tokens_in => 0, tokens_out => 0, total_tokens => 0, llm_calls => 0, turns => 0},
    maps:merge(Base, Overrides).
