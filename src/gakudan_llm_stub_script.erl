-module(gakudan_llm_stub_script).
-moduledoc """
Tiny gen_server holding a queue of canned LLM responses for tests/offline demos.
""".

-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link(Responses) when is_list(Responses) ->
    gen_server:start_link(?MODULE, Responses, []).

init(Responses) ->
    {ok, Responses}.

handle_call(next, _From, []) ->
    {reply, empty, []};
handle_call(next, _From, [H | T]) ->
    {reply, {ok, H}, T}.

handle_cast(_, S) ->
    {noreply, S}.
