-module(gakudan_sup).
-moduledoc false.

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => rest_for_one, intensity => 5, period => 10},
    Children = [
        #{
            id => gakudan_registry,
            start => {gakudan_registry, start_link, []},
            type => worker
        },
        #{
            id => gakudan_runs_sup,
            start => {gakudan_runs_sup, start_link, []},
            type => supervisor
        },
        #{
            id => gakudan_runs_resumer,
            start => {gakudan_runs_resumer, start_link, []},
            restart => transient,
            type => worker
        }
    ],
    {ok, {SupFlags, Children}}.
