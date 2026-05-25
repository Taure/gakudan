-module(gakudan_run).
-moduledoc """
Run-level operations. Looks up the run by id via `gakudan_registry`
and delegates to the run's gen_statem.
""".

-export([send/2, status/1, stop/1, await/2, blackboard/1, interrupt/2, resume/2]).

-spec send(gakudan:run_id(), binary()) -> ok | {error, not_found}.
send(RunId, Message) ->
    with_run(RunId, fun(#{run_statem := Pid}) -> gakudan_run_statem:send(Pid, Message) end).

-spec status(gakudan:run_id()) -> {ok, atom()} | {error, not_found}.
status(RunId) ->
    with_run(RunId, fun(#{run_statem := Pid}) -> gakudan_run_statem:status(Pid) end).

-spec stop(gakudan:run_id()) -> ok | {error, not_found}.
stop(RunId) ->
    with_run(RunId, fun(#{run_sup := Sup}) -> gakudan_runs_sup:stop_run(Sup) end).

-spec await(gakudan:run_id(), timeout()) ->
    {ok, [gakudan_blackboard:entry()]} | {error, timeout | not_found}.
await(RunId, Timeout) ->
    with_run(RunId, fun(#{run_statem := Pid}) -> gakudan_run_statem:await(Pid, Timeout) end).

-spec blackboard(gakudan:run_id()) -> {ok, pid()} | {error, not_found}.
blackboard(RunId) ->
    with_run(RunId, fun(#{blackboard := Pid}) -> {ok, Pid} end).

-spec interrupt(gakudan:run_id(), term()) -> ok | {error, not_found | not_interruptible}.
interrupt(RunId, Reason) ->
    with_run(RunId, fun(#{run_statem := Pid}) -> gakudan_run_statem:interrupt(Pid, Reason) end).

-spec resume(gakudan:run_id(), term()) -> ok | {error, not_found | not_interrupted}.
resume(RunId, Payload) ->
    with_run(RunId, fun(#{run_statem := Pid}) -> gakudan_run_statem:resume(Pid, Payload) end).

with_run(RunId, Fun) ->
    case gakudan_registry:lookup(RunId) of
        {ok, Entry} -> Fun(Entry);
        {error, not_found} = E -> E
    end.
