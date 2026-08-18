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
    ?assert(gakudan_llm_retry:transient({http_error, 429, ~"rate limited"})),
    ?assertNot(gakudan_llm_retry:transient({http_error, 400, ~"x"})),
    ?assertNot(gakudan_llm_retry:transient({http_error, 404, ~"x"})),
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

retry_retries_rate_limit_test() ->
    Pid = spawn_results([{error, {http_error, 429, ~"slow down"}}, {ok, ?OK_RESP}]),
    Opts = #{
        backend => {scripted_llm_mod, #{results => Pid}},
        max_attempts => 3,
        base_delay => 1
    },
    ?assertEqual({ok, ?OK_RESP}, gakudan_llm_retry:complete(?REQ, Opts)),
    stop_results(Pid).

retry_backoff_is_interrupted_test_() ->
    {timeout, 30, fun() ->
        Pid = spawn_results([{error, timeout}, {ok, ?OK_RESP}]),
        Self = self(),
        spawn(fun() ->
            timer:sleep(100),
            Self ! gakudan_llm_cancel
        end),
        Opts = #{
            backend => {scripted_llm_mod, #{results => Pid}},
            max_attempts => 3,
            base_delay => 10000
        },
        T0 = erlang:monotonic_time(millisecond),
        Result = gakudan_llm_retry:complete(?REQ, Opts),
        Elapsed = erlang:monotonic_time(millisecond) - T0,
        stop_results(Pid),
        ?assertEqual({error, cancelled}, Result),
        ?assert(Elapsed < 3000)
    end}.

retry_cancelled_backoff_leaves_clean_mailbox_test() ->
    Pid = spawn_results([{error, timeout}, {ok, ?OK_RESP}]),
    self() ! gakudan_llm_cancel,
    Opts = #{backend => {scripted_llm_mod, #{results => Pid}}, base_delay => 5000},
    ?assertEqual({error, cancelled}, gakudan_llm_retry:complete(?REQ, Opts)),
    stop_results(Pid),
    ?assertEqual({messages, []}, erlang:process_info(self(), messages)).

retry_stream_backoff_cancel_notifies_subscriber_test() ->
    Pid = spawn_results([{error, timeout}, {ok, ?OK_RESP}]),
    Ref = make_ref(),
    Sub = spawn_collector(self()),
    self() ! gakudan_llm_cancel,
    Opts = #{
        backend => {scripted_llm_mod, #{results => Pid}},
        stream_request_id => Ref,
        base_delay => 5000
    },
    ?assertEqual({error, cancelled}, gakudan_llm_retry:stream_call(?REQ, Opts, Sub)),
    stop_results(Pid),
    receive
        {collected, Events} -> ?assertEqual([{cancelled, #{}}], Events)
    after 1000 -> ?assert(false)
    end.

retry_complete_backoff_cancel_emits_nothing_test() ->
    Pid = spawn_results([{error, timeout}, {ok, ?OK_RESP}]),
    self() ! gakudan_llm_cancel,
    Opts = #{backend => {scripted_llm_mod, #{results => Pid}}, base_delay => 5000},
    ?assertEqual({error, cancelled}, gakudan_llm_retry:complete(?REQ, Opts)),
    stop_results(Pid),
    ?assertEqual({messages, []}, erlang:process_info(self(), messages)).

spawn_collector(Parent) ->
    spawn(fun() -> collect(Parent, []) end).

collect(Parent, Acc) ->
    receive
        {gakudan_llm_stream, _R, Ev} -> collect(Parent, [Ev | Acc])
    after 300 -> Parent ! {collected, lists:reverse(Acc)}
    end.

retry_backoff_without_cancel_still_retries_test() ->
    Pid = spawn_results([{error, timeout}, {ok, ?OK_RESP}]),
    Opts = #{
        backend => {scripted_llm_mod, #{results => Pid}},
        max_attempts => 3,
        base_delay => 1
    },
    ?assertEqual({ok, ?OK_RESP}, gakudan_llm_retry:complete(?REQ, Opts)),
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
