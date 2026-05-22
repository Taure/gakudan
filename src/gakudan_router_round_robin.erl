-module(gakudan_router_round_robin).
-moduledoc """
Round-robin router: cycles through agents, one turn each.

Opts: `#{rounds => pos_integer()}` - stop after this many full rounds (default 1).
""".

-behaviour(gakudan_router).

-export([init/2, next/2]).

init(Opts, Agents) ->
    Rounds = maps:get(rounds, Opts, 1),
    {ok, #{queue => Agents, original => Agents, remaining_rounds => Rounds}}.

next(#{queue := [], remaining_rounds := 1} = State, _Transcript) ->
    {done, State#{remaining_rounds := 0}};
next(#{queue := [], remaining_rounds := R, original := Orig} = State, Transcript) when R > 1 ->
    next(State#{queue := Orig, remaining_rounds := R - 1}, Transcript);
next(#{queue := [Next | Rest]} = State, _Transcript) ->
    {next, Next, State#{queue := Rest}}.
