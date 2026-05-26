-module(gakudan_router_fanout).
-moduledoc """
Fan-out router: runs every agent concurrently, one parallel round at a time.

The parallel analogue of `gakudan_router_round_robin`. Each call to
`next/2` returns a `fanout` of all agents; after `rounds` rounds it is
done. Useful for ensemble / poll / map topologies where the agents do
not depend on one another within a round.

Opts: `#{rounds => pos_integer()}` - number of parallel rounds (default 1).

See [ADR 0007](docs/adr/0007-parallel-agent-execution.md).
""".

-behaviour(gakudan_router).

-export([init/2, next/2]).

init(Opts, Agents) ->
    Rounds = maps:get(rounds, Opts, 1),
    {ok, #{agents => Agents, remaining_rounds => Rounds}}.

next(#{remaining_rounds := 0} = State, _Transcript) ->
    {done, State};
next(#{agents := Agents, remaining_rounds := R} = State, _Transcript) ->
    {fanout, Agents, State#{remaining_rounds := R - 1}}.
