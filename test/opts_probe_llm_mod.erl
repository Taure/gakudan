-module(opts_probe_llm_mod).
-moduledoc false.
-behaviour(gakudan_llm).

-export([complete/2]).

complete(_Req, Opts) ->
    case maps:get(probe_owner, Opts, undefined) of
        undefined -> ok;
        Pid -> Pid ! {seen_opts, Opts}
    end,
    {ok, #{stop_reason => end_turn, content => [#{type => text, text => ~"ack"}]}}.
