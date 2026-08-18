-module(slow_init_checkpointer).
-moduledoc false.
-behaviour(gakudan_checkpointer).

-export([init/1, save_snapshot/2, load_snapshot/2, list_active/1, delete_run/2]).
-export([save_step/2, load_step/3, save_tool_result/2, load_tool_result/3]).

init(Opts) -> {ok, Opts}.

%% Outlasts gakudan_runs_sup's wait_ready timeout, so start_run/1 raises while
%% the run itself is alive and stays alive.
load_snapshot(_S, _RunId) ->
    timer:sleep(7000),
    {error, not_found}.

save_snapshot(_S, _Snapshot) -> ok.
list_active(_S) -> {ok, []}.
delete_run(_S, _RunId) -> ok.
save_step(_S, _Step) -> ok.
load_step(_S, _RunId, _StepId) -> {error, not_found}.
save_tool_result(_S, _R) -> ok.
load_tool_result(_S, _RunId, _StepId) -> {error, not_found}.
