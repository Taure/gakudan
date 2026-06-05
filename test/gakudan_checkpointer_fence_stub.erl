-module(gakudan_checkpointer_fence_stub).
-moduledoc false.

%% Test double: every snapshot write is refused with `lease_lost`, and the
%% status it was asked to persist is reported to a pid. Lets a statem-level
%% test prove the fence path tears the run down without writing a failed
%% snapshot (ADR 0023).

-behaviour(gakudan_checkpointer).

-export([
    init/1,
    save_snapshot/2,
    load_snapshot/2,
    list_active/1,
    delete_run/2,
    save_step/2,
    load_step/3,
    save_tool_result/2,
    load_tool_result/3
]).

init(#{report := Pid}) -> {ok, #{report => Pid}}.

save_snapshot(#{report := Pid}, #{status := Status}) ->
    Pid ! {fence_save, Status},
    {error, lease_lost}.

load_snapshot(_State, _RunId) -> {error, not_found}.

list_active(_State) -> {ok, []}.

delete_run(_State, _RunId) -> ok.

save_step(_State, _Step) -> ok.

load_step(_State, _RunId, _StepId) -> {error, not_found}.

save_tool_result(_State, _Record) -> ok.

load_tool_result(_State, _RunId, _ToolStepId) -> {error, not_found}.
