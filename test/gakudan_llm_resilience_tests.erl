-module(gakudan_llm_resilience_tests).
-include_lib("eunit/include/eunit.hrl").

-define(REQ, #{model => ~"m", system => ~"s", tools => [], messages => []}).
-define(OK_RESP, #{stop_reason => end_turn, content => [#{type => text, text => ~"hi"}]}).

%%% fallback %%%

fallback_first_success_test() ->
    Opts = #{
        backends => [
            {scripted_llm_mod, #{result => {ok, ?OK_RESP}}},
            {scripted_llm_mod, #{result => {error, should_not_run}}}
        ]
    },
    ?assertEqual({ok, ?OK_RESP}, gakudan_llm_fallback:complete(?REQ, Opts)).

fallback_falls_through_to_next_test() ->
    Opts = #{
        backends => [
            {scripted_llm_mod, #{result => {error, boom}}},
            {scripted_llm_mod, #{result => {ok, ?OK_RESP}}}
        ]
    },
    ?assertEqual({ok, ?OK_RESP}, gakudan_llm_fallback:complete(?REQ, Opts)).

fallback_returns_last_error_test() ->
    Opts = #{
        backends => [
            {scripted_llm_mod, #{result => {error, first}}},
            {scripted_llm_mod, #{result => {error, last}}}
        ]
    },
    ?assertEqual({error, last}, gakudan_llm_fallback:complete(?REQ, Opts)).

fallback_no_backends_test() ->
    ?assertEqual({error, no_backends}, gakudan_llm_fallback:complete(?REQ, #{backends => []})).

fallback_does_not_retry_on_cancel_test() ->
    Opts = #{
        backends => [
            {scripted_llm_mod, #{result => {error, cancelled}}},
            {scripted_llm_mod, #{result => {ok, ?OK_RESP}}}
        ]
    },
    ?assertEqual({error, cancelled}, gakudan_llm_fallback:complete(?REQ, Opts)).

%%% retry %%%

retry_transient_classification_test() ->
    ?assert(gakudan_llm_retry:transient(timeout)),
    ?assert(gakudan_llm_retry:transient({http_error, 503, ~"x"})),
    ?assert(gakudan_llm_retry:transient(closed)),
    ?assertNot(gakudan_llm_retry:transient({http_error, 400, ~"x"})),
    ?assertNot(gakudan_llm_retry:transient(no_api_key)),
    ?assertNot(gakudan_llm_retry:transient(cancelled)).

retry_backoff_grows_and_caps_test() ->
    ?assertEqual(100, gakudan_llm_retry:backoff_delay(1, 100, 5000)),
    ?assertEqual(200, gakudan_llm_retry:backoff_delay(2, 100, 5000)),
    ?assertEqual(400, gakudan_llm_retry:backoff_delay(3, 100, 5000)),
    ?assertEqual(5000, gakudan_llm_retry:backoff_delay(10, 100, 5000)).

retry_succeeds_after_transient_test() ->
    Pid = spawn_results([{error, timeout}, {error, timeout}, {ok, ?OK_RESP}]),
    Opts = #{
        backend => {scripted_llm_mod, #{results => Pid}},
        max_attempts => 3,
        base_delay => 1
    },
    ?assertEqual({ok, ?OK_RESP}, gakudan_llm_retry:complete(?REQ, Opts)),
    stop_results(Pid).

retry_gives_up_after_max_attempts_test() ->
    Pid = spawn_results([{error, timeout}, {error, timeout}, {error, timeout}]),
    Opts = #{
        backend => {scripted_llm_mod, #{results => Pid}},
        max_attempts => 2,
        base_delay => 1
    },
    ?assertEqual({error, timeout}, gakudan_llm_retry:complete(?REQ, Opts)),
    stop_results(Pid).

retry_does_not_retry_client_error_test() ->
    Pid = spawn_results([{error, {http_error, 400, ~"bad"}}, {ok, ?OK_RESP}]),
    Opts = #{
        backend => {scripted_llm_mod, #{results => Pid}},
        max_attempts => 3,
        base_delay => 1
    },
    ?assertEqual({error, {http_error, 400, ~"bad"}}, gakudan_llm_retry:complete(?REQ, Opts)),
    stop_results(Pid).

%%% retry over fallback composition %%%

retry_wrapping_fallback_test() ->
    Pid = spawn_results([{error, timeout}, {ok, ?OK_RESP}]),
    Inner =
        {gakudan_llm_fallback, #{
            backends => [{scripted_llm_mod, #{results => Pid}}]
        }},
    Opts = #{backend => Inner, max_attempts => 2, base_delay => 1},
    ?assertEqual({ok, ?OK_RESP}, gakudan_llm_retry:complete(?REQ, Opts)),
    stop_results(Pid).

spawn_results(Results) ->
    spawn(fun() -> results_loop(Results) end).

results_loop(Results) ->
    receive
        {next, From} ->
            case Results of
                [R | Rest] ->
                    From ! {result, R},
                    results_loop(Rest);
                [] ->
                    From ! {result, {error, exhausted}},
                    results_loop([])
            end;
        stop ->
            ok
    end.

stop_results(Pid) ->
    Pid ! stop.
