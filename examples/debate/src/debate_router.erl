-module(debate_router).
-moduledoc """
Custom router: cycles the debaters for N rounds, then forces one synthesiser
turn at the end.

This example shows how to plug your own router into gakudan: implement the
`gakudan_router` behaviour and pass `{debate_router, Opts}` in the run config.

Opts: `#{rounds := pos_integer(), debaters := [atom()], synthesiser := atom()}`.
""".

-behaviour(gakudan_router).

-export([init/2, next/2]).

init(#{rounds := Rounds, debaters := Debaters, synthesiser := Synth}, Agents) ->
    All = [Synth | Debaters],
    case lists:all(fun(A) -> lists:member(A, Agents) end, All) of
        true ->
            {ok, #{
                queue => expand_queue(Rounds, Debaters),
                synthesiser => Synth,
                synth_done => false
            }};
        false ->
            error({debate_router_missing_agents, All, Agents})
    end.

next(#{queue := [Next | Rest]} = State, _Transcript) ->
    {next, Next, State#{queue := Rest}};
next(#{queue := [], synth_done := false, synthesiser := Synth} = State, _Transcript) ->
    {next, Synth, State#{synth_done := true}};
next(#{queue := [], synth_done := true} = State, _Transcript) ->
    {done, State}.

expand_queue(Rounds, Debaters) ->
    lists:append(lists:duplicate(Rounds, Debaters)).
