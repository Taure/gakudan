-module(gakudan_stream_tests).
-include_lib("eunit/include/eunit.hrl").

%% A slow subscriber that never drains until told, so the pubsub sees its
%% mailbox grow and sheds load.
load_shedding_test() ->
    application:set_env(gakudan, stream_max_queue, 3),
    {ok, S} = gakudan_stream:start_link(~"run-shed"),
    Parent = self(),
    Sub = spawn(fun() -> slow_subscriber(S, Parent) end),
    receive
        subscribed -> ok
    end,
    [
        gakudan_stream:publish(
            S, #{agent_id => a, request_id => make_ref()}, {text_delta, integer_to_binary(I)}
        )
     || I <- lists:seq(1, 10)
    ],
    timer:sleep(50),
    Sub ! report1,
    First =
        receive
            {first, F} -> F
        after 2000 -> ?assert(false)
        end,
    %% Load was shed: fewer than 10 delivered, but at least one got through.
    ?assert(length(First) < 10),
    ?assert(length(First) >= 1),
    %% Drain, then one more publish carries the coalesced drop count.
    gakudan_stream:publish(S, #{agent_id => a, request_id => make_ref()}, {text_delta, ~"resume"}),
    timer:sleep(50),
    Sub ! report2,
    Second =
        receive
            {second, Sec} -> Sec
        after 2000 -> ?assert(false)
        end,
    [Resumed] = Second,
    ?assertEqual(10 - length(First), maps:get(dropped, Resumed)),
    gen_server:stop(S).

no_drop_for_fast_subscriber_test() ->
    application:set_env(gakudan, stream_max_queue, 10000),
    {ok, S} = gakudan_stream:start_link(~"run-fast"),
    {ok, _Ref} = gakudan_stream:subscribe(S),
    [
        gakudan_stream:publish(
            S, #{agent_id => a, request_id => make_ref()}, {text_delta, integer_to_binary(I)}
        )
     || I <- lists:seq(1, 10)
    ],
    Events = drain([]),
    ?assertEqual(10, length(Events)),
    ?assert(lists:all(fun(M) -> not maps:is_key(dropped, M) end, Events)),
    gen_server:stop(S).

drain(Acc) ->
    receive
        {gakudan_stream, _RunId, Event} -> drain([Event | Acc])
    after 200 ->
        lists:reverse(Acc)
    end.

slow_subscriber(StreamPid, Parent) ->
    {ok, _Ref} = gakudan_stream:subscribe(StreamPid),
    Parent ! subscribed,
    receive
        report1 -> ok
    end,
    Parent ! {first, collect([])},
    receive
        report2 -> ok
    end,
    Parent ! {second, collect([])}.

collect(Acc) ->
    receive
        {gakudan_stream, _RunId, Event} -> collect([Event | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.
