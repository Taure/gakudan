-module(scripted_llm_mod).
-moduledoc false.
-behaviour(gakudan_llm).

-export([complete/2, stream_call/3]).

%% A backend whose result is taken straight from its opts, so resilience
%% wrappers can be exercised deterministically without HTTP.
%%
%% Opts:
%%   result   => {ok, Resp} | {error, Reason}  (a fixed result), or
%%   results  => Pid                            (a counter agent that
%%                                               returns the next result)
complete(_Req, #{result := Result}) ->
    Result;
complete(_Req, #{results := Pid}) ->
    next(Pid).

stream_call(_Req, Opts, _Subscriber) ->
    complete(undefined, Opts).

next(Pid) ->
    Pid ! {next, self()},
    receive
        {result, R} -> R
    after 1000 -> {error, test_timeout}
    end.
