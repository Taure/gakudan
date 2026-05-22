-module(gakudan_eval_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    happy_path_round_robin/1,
    handoff_with_substring_match/1,
    failing_expectation_returns_error/1,
    tokens_accumulate_from_stub/1,
    assert_passed_crashes_on_failure/1,
    unknown_expectation_is_a_failure/1
]).

all() ->
    [
        happy_path_round_robin,
        handoff_with_substring_match,
        failing_expectation_returns_error,
        tokens_accumulate_from_stub,
        assert_passed_crashes_on_failure,
        unknown_expectation_is_a_failure
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(gakudan),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(gakudan),
    ok.

happy_path_round_robin(_Config) ->
    {ok, Report} = gakudan_eval:run(#{
        name => happy_path,
        config => #{
            agents => [agent_a_mod, agent_b_mod],
            router => {gakudan_router_round_robin, #{}},
            max_turns => 4
        },
        script => [{text, ~"a reply"}, {text, ~"b reply"}],
        input => ~"go",
        expect => [
            {outcome, idle},
            {min_turns, 2},
            no_failed_turns
        ]
    }),
    ?assertEqual([], maps:get(failed, Report)),
    ?assertEqual(happy_path, maps:get(name, Report)).

handoff_with_substring_match(_Config) ->
    {ok, Report} = gakudan_eval:run(#{
        config => #{
            agents => [agent_a_mod, agent_b_mod],
            router => {gakudan_router_handoff, #{start => agent_a}},
            max_turns => 4
        },
        script => [
            {text, ~"plan done. @agent_b take it from here"},
            {text, ~"acknowledged, nothing more to do"}
        ],
        input => ~"start",
        expect => [
            {outcome, idle},
            {agent_turn_contains, agent_a, ~"plan done"},
            {agent_turn_contains, agent_b, ~"acknowledged"},
            {agent_turn_count, agent_a, 1},
            {agent_turn_count, agent_b, 1}
        ]
    }),
    ?assertEqual([], maps:get(failed, Report)).

failing_expectation_returns_error(_Config) ->
    {error, Report} = gakudan_eval:run(#{
        config => #{
            agents => [agent_a_mod, agent_b_mod],
            router => {gakudan_router_round_robin, #{}},
            max_turns => 4
        },
        script => [{text, ~"only this"}],
        input => ~"go",
        expect => [
            {agent_turn_contains, agent_a, ~"this string is never produced"}
        ]
    }),
    [{_Exp, _Reason}] = maps:get(failed, Report).

tokens_accumulate_from_stub(_Config) ->
    {ok, Report} = gakudan_eval:run(#{
        config => #{
            agents => [agent_a_mod, agent_b_mod],
            router => {gakudan_router_round_robin, #{}},
            max_turns => 4
        },
        script => [{text, ~"hi"}, {text, ~"hi"}],
        input => ~"go",
        expect => [{tokens_input_at_least, 0}]
    }),
    ?assertEqual([], maps:get(failed, Report)).

assert_passed_crashes_on_failure(_Config) ->
    Result = gakudan_eval:run(#{
        config => #{
            agents => [agent_a_mod, agent_b_mod],
            router => {gakudan_router_round_robin, #{}},
            max_turns => 4
        },
        script => [{text, ~"x"}],
        input => ~"go",
        expect => [{transcript_min_length, 999}]
    }),
    ?assertError({eval_failed, _, _}, gakudan_eval:assert_passed(Result)).

unknown_expectation_is_a_failure(_Config) ->
    {error, Report} = gakudan_eval:run(#{
        config => #{
            agents => [agent_a_mod, agent_b_mod],
            router => {gakudan_router_round_robin, #{}},
            max_turns => 4
        },
        script => [{text, ~"x"}],
        input => ~"go",
        expect => [{not_a_real_expectation, foo}]
    }),
    [{{not_a_real_expectation, foo}, _}] = maps:get(failed, Report).
