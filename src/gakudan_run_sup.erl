-module(gakudan_run_sup).
-moduledoc false.

-behaviour(supervisor).

-export([start_link/1, start_link/2]).
-export([init/1]).

start_link(Config) ->
    supervisor:start_link(?MODULE, {fresh, Config}).

start_link(Config, Snapshot) ->
    supervisor:start_link(?MODULE, {resume, Config, Snapshot}).

init({fresh, #{run_id := RunId} = Config}) ->
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
    {ok, {SupFlags, Children}};
init({resume, #{run_id := RunId} = Config, Snapshot}) ->
    SupFlags = #{strategy => one_for_all, intensity => 5, period => 10},
    Self = self(),
    Restore = #{
        entries => maps:get(blackboard, Snapshot, []),
        kv => maps:get(kv, Snapshot, #{})
    },
    Children = [
        #{
            id => blackboard,
            start => {gakudan_blackboard, start_link, [RunId, Restore]},
            type => worker
        },
        #{
            id => run_statem,
            start => {gakudan_run_statem, start_link, [Self, Config, Snapshot]},
            type => worker
        }
    ],
    {ok, {SupFlags, Children}}.
