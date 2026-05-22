-module(gakudan_router).
-moduledoc """
Routing behaviour. A router decides which agent runs the next turn.

Routers are stateful; the run state machine threads the state through.
""".

-export_type([state/0]).

-type state() :: term().

-callback init(Opts :: map(), Agents :: [gakudan_agent:id()]) -> {ok, state()}.
-callback next(state(), Transcript :: [gakudan_blackboard:entry()]) ->
    {next, gakudan_agent:id(), state()} | {done, state()}.
