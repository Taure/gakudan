-module(gakudan_router_loop).
-moduledoc """
Loop router: run one agent (or cycle a list of agents) repeatedly until a
predicate says stop or a maximum iteration count is hit.

This is the "keep going until done" primitive - a refine-until-good or
poll-until-ready loop - without an external driver.

Opts:
- `agents := [AgentId]` - the agents to run, one per turn, cycling. A
  single-element list is the common "run this agent in a loop" case.
- `until := fun(([gakudan_blackboard:entry()]) -> boolean())` - called
  after each completed turn; returning `true` ends the run. Default: never
  stops (relies on `max_iterations`).
- `max_iterations := pos_integer()` - hard cap on turns, so a loop always
  terminates. Default 10.

The predicate sees the full transcript and decides on observable state
(an agent wrote `DONE`, a blackboard value crossed a threshold, etc.).
""".

-behaviour(gakudan_router).

-export([init/2, next/2]).

-define(DEFAULT_MAX_ITERATIONS, 10).

init(Opts, Agents) ->
    Loop = maps:get(agents, Opts, Agents),
    case Loop =/= [] andalso lists:all(fun(A) -> lists:member(A, Agents) end, Loop) of
        true ->
            {ok, #{
                agents => Loop,
                queue => Loop,
                until => maps:get(until, Opts, fun(_Transcript) -> false end),
                max_iterations => maps:get(max_iterations, Opts, ?DEFAULT_MAX_ITERATIONS),
                iterations => 0,
                started => false
            }};
        false ->
            error({loop_router_bad_agents, Loop, Agents})
    end.

next(#{started := false, queue := [A | Rest]} = State, _Transcript) ->
    {next, A, State#{started := true, queue := Rest, iterations := 1}};
next(#{iterations := I, max_iterations := Max} = State, _Transcript) when I >= Max ->
    {done, State};
next(#{until := Until} = State, Transcript) ->
    case Until(Transcript) of
        true ->
            {done, State};
        false ->
            {A, State1} = dequeue(State),
            {next, A, State1#{iterations := maps:get(iterations, State1) + 1}}
    end.

dequeue(#{queue := [], agents := Agents} = State) ->
    dequeue(State#{queue := Agents});
dequeue(#{queue := [A | Rest]} = State) ->
    {A, State#{queue := Rest}}.
