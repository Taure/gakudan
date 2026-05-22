-module(gakudan_run_sup).
-moduledoc false.

-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

start_link(Config) ->
    supervisor:start_link(?MODULE, Config).

init(#{run_id := RunId} = Config) ->
    SupFlags = #{strategy => one_for_all, intensity => 5, period => 10},
    Self = self(),
    Children = [
        #{
            id => blackboard,
            start => {gakudan_blackboard, start_link, [RunId]},
            type => worker
        },
        #{
            id => run_statem,
            start => {gakudan_run_statem, start_link, [Self, Config]},
            type => worker
        }
    ],
    {ok, {SupFlags, Children}}.
