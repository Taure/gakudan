-module(gakudan_router).
-moduledoc """
Routing behaviour. A router decides which agent runs the next turn.

Routers are stateful; the run state machine threads the state through.

The `Agents` argument passed to `c:init/2` is the list of agent **IDs**
(the values returned by each agent module's `c:gakudan_agent:id/0`),
**not** the list of module names. A module `my_app_agent_risk` whose
`id/0` returns `risk` will appear in `Agents` as the atom `risk`. Routers
should compare and dispatch in terms of those IDs.
""".

-export_type([state/0]).

-type state() :: term().

-doc """
Initialise router state.

`Agents` is the list of `t:gakudan_agent:id/0` values for the agents
participating in this run, in the order they were registered. These are
the IDs returned by each agent's `c:gakudan_agent:id/0` callback, which
may differ from the module name.
""".
-callback init(Opts :: map(), Agents :: [gakudan_agent:id()]) -> {ok, state()}.

-doc """
Decide what runs next, given the router state and the current transcript.

- `{next, Id, State}` runs agent `Id` as the next turn.
- `{fanout, Ids, State}` runs every agent in `Ids` concurrently as one
  parallel round; the router is consulted again only once all of them
  have finished and appended their output. `{next, Id, State}` is the
  degenerate fanout of one. See
  [ADR 0007](docs/adr/0007-parallel-agent-execution.md).
- `{done, State}` ends the run.
""".
-callback next(state(), Transcript :: [gakudan_blackboard:entry()]) ->
    {next, gakudan_agent:id(), state()}
    | {fanout, [gakudan_agent:id()], state()}
    | {done, state()}.
