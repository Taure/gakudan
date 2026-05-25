-module(gakudan_runs_sup).
-moduledoc false.

-behaviour(supervisor).

-export([start_link/0, start_run/1, resume_run/2, stop_run/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_run(gakudan:run_config()) -> {ok, pid(), gakudan:run_id()} | {error, term()}.
start_run(Config) ->
    case supervisor:start_child(?MODULE, [Config]) of
        {ok, SupPid} ->
            wait_ready_and_return(SupPid, Config);
        {error, _} = Err ->
            Err
    end.

-spec resume_run(gakudan:run_config(), map()) -> {ok, pid(), gakudan:run_id()} | {error, term()}.
resume_run(Config, Snapshot) ->
    case supervisor:start_child(?MODULE, [Config, Snapshot]) of
        {ok, SupPid} ->
            wait_ready_and_return(SupPid, Config);
        {error, _} = Err ->
            Err
    end.

wait_ready_and_return(SupPid, Config) ->
    RunId = maps:get(run_id, Config),
    {run_statem, StatemPid, _, _} = lists:keyfind(
        run_statem, 1, supervisor:which_children(SupPid)
    ),
    ok = gakudan_run_statem:wait_ready(StatemPid),
    {ok, SupPid, RunId}.

-spec stop_run(pid()) -> ok | {error, not_found}.
stop_run(SupPid) when is_pid(SupPid) ->
    supervisor:terminate_child(?MODULE, SupPid).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one, intensity => 10, period => 60},
    Children = [
        #{
            id => gakudan_run_sup,
            start => {gakudan_run_sup, start_link, []},
            restart => temporary,
            type => supervisor
        }
    ],
    {ok, {SupFlags, Children}}.
