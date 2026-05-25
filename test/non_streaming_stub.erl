-module(non_streaming_stub).
-moduledoc false.

-behaviour(gakudan_llm).

-export([complete/2]).

complete(_Req, Opts) ->
    Text = maps:get(response_text, Opts, ~"ok"),
    {ok, #{
        stop_reason => end_turn,
        content => [#{type => text, text => Text}]
    }}.
