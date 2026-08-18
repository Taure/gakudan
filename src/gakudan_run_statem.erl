-module(gakudan_run_statem).
-moduledoc false.

-behaviour(gen_statem).

-include_lib("kernel/include/logger.hrl").

-export([start_link/2, start_link/3, send/2, status/1, stop/1, await/2, wait_ready/1]).
-export([interrupt/2, resume/2, cancel/1]).
-export([callback_mode/0, init/1, handle_event/4, terminate/3]).
-export([format_status/1]).

-record(data, {
    run_id :: gakudan:run_id(),
    run_sup :: pid(),
    blackboard :: undefined | pid(),
    stream :: undefined | pid(),
    config :: gakudan:run_config(),
    guardrails = [] :: [gakudan_guardrail:ref()],
    agents :: #{atom() => {module(), map()}},
    agent_ids :: [atom()],
    router_mod :: module(),
    router_state :: term(),
    llm_mod :: module(),
    llm_opts :: map(),
    max_turns :: pos_integer(),
    turn = 0 :: non_neg_integer(),
    last_step = 0 :: non_neg_integer(),
    checkpointer :: undefined | {module(), term()},
    audit = undefined :: gakudan_audit:handle(),
    actor = #{} :: map(),
    context = undefined :: undefined | gakudan_context:ref(),
    budget = undefined :: undefined | gakudan_budget:ref(),
    used = #{tokens_in => 0, tokens_out => 0, llm_calls => 0} :: gakudan_turn:usage(),
    stopped = undefined :: undefined | term(),
    credential_source = environment :: vault | environment,
    cancelling = false :: boolean(),
    turn_workers = #{} ::
        #{
            pid() => #{
                pid := pid(),
                mon_ref := reference(),
                agent_id := atom(),
                turn := pos_integer(),
                start_time := integer()
            }
        },
    fanout = undefined :: undefined | #{base := non_neg_integer(), agents := [gakudan_agent:id()]},
    awaiters = [] :: [{pid(), reference()}],
    start_time :: integer()
}).

start_link(RunSup, Config) ->
    gen_statem:start_link(?MODULE, {fresh, RunSup, Config}, []).

start_link(RunSup, Config, Snapshot) ->
    gen_statem:start_link(?MODULE, {resume, RunSup, Config, Snapshot}, []).

-spec send(pid(), binary()) -> ok.
send(Pid, Message) ->
    gen_statem:cast(Pid, {user_message, Message}).

-spec interrupt(pid(), term()) -> ok.
interrupt(Pid, Reason) ->
    gen_statem:call(Pid, {interrupt, Reason}).

-spec resume(pid(), term()) -> ok | {error, not_interrupted}.
resume(Pid, Payload) ->
    gen_statem:call(Pid, {resume, Payload}).

-spec cancel(pid()) -> ok.
cancel(Pid) ->
    gen_statem:call(Pid, cancel).

-spec status(pid()) -> {ok, atom()}.
status(Pid) ->
    gen_statem:call(Pid, status).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_statem:stop(Pid).

-spec await(pid(), timeout()) -> {ok, [gakudan_blackboard:entry()]} | {error, timeout}.
await(Pid, Timeout) ->
    gen_statem:call(Pid, {await, Timeout}, infinity).

-spec wait_ready(pid()) -> ok.
wait_ready(Pid) ->
    gen_statem:call(Pid, wait_ready, 5000).

callback_mode() ->
    [handle_event_function, state_enter].

init({fresh, RunSup, Config}) ->
    process_flag(trap_exit, true),
    #{run_id := RunId, agents := AgentsRaw, router := {RMod, ROpts}} = Config,
    {LMod, LOpts} = live_llm_spec(Config),
    MaxTurns = maps:get(max_turns, Config, 16),
    Agents = build_agents_map(AgentsRaw),
    AgentIds = [agent_id(S) || S <- AgentsRaw],
    {ok, RouterState} = RMod:init(ROpts, AgentIds),
    Checkpointer = init_checkpointer(Config),
    Data = #data{
        run_id = RunId,
        run_sup = RunSup,
        blackboard = undefined,
        config = Config,
        guardrails = maps:get(guardrails, Config, []),
        agents = Agents,
        agent_ids = AgentIds,
        router_mod = RMod,
        router_state = RouterState,
        llm_mod = LMod,
        llm_opts = LOpts,
        credential_source = credential_source(Config),
        max_turns = MaxTurns,
        checkpointer = Checkpointer,
        audit = init_audit(Config),
        actor = maps:get(actor, Config, #{}),
        context = init_context(Config),
        budget = init_budget(Config),
        start_time = erlang:monotonic_time()
    },
    {ok, initialising, Data, [{next_event, internal, finish_init}]};
init({resume, RunSup, Config, Snapshot}) ->
    process_flag(trap_exit, true),
    #{run_id := RunId, agents := AgentsRaw, router := {RMod, _ROpts}} = Config,
    {LMod, LOpts} = live_llm_spec(Config),
    MaxTurns = maps:get(max_turns, Config, 16),
    Agents = build_agents_map(AgentsRaw),
    AgentIds = [agent_id(S) || S <- AgentsRaw],
    #{
        router_state := RouterState,
        turn := Turn,
        last_step := LastStep,
        statem_state := PriorState
    } = Snapshot,
    Checkpointer = init_checkpointer(Config),
    Data = #data{
        run_id = RunId,
        run_sup = RunSup,
        blackboard = undefined,
        config = Config,
        guardrails = maps:get(guardrails, Config, []),
        agents = Agents,
        agent_ids = AgentIds,
        router_mod = RMod,
        router_state = RouterState,
        llm_mod = LMod,
        llm_opts = LOpts,
        credential_source = credential_source(Config),
        max_turns = MaxTurns,
        turn = Turn,
        last_step = LastStep,
        fanout = maps:get(fanout, Snapshot, undefined),
        checkpointer = Checkpointer,
        audit = init_audit(Config),
        actor = maps:get(actor, Config, #{}),
        context = init_context(Config),
        budget = init_budget(Config),
        start_time = erlang:monotonic_time()
    },
    Restore = #{
        entries => maps:get(blackboard, Snapshot, []),
        kv => maps:get(kv, Snapshot, #{})
    },
    {ok, initialising, Data, [{next_event, internal, {finish_resume, PriorState, Restore}}]}.

handle_event(enter, _Old, initialising, _Data) ->
    keep_state_and_data;
handle_event(internal, finish_init, initialising, Data) ->
    Data1 = register_children(Data),
    case load_active_snapshot(Data1) of
        {ok, Snapshot} ->
            %% A snapshot for this run already exists: this is a
            %% supervised restart, so rehydrate instead of starting fresh.
            Data2 = rehydrate(Data1, Snapshot),
            emit_run_start(Data2),
            emit_audit(Data2, run_resumed, #{mode => supervised, origin => init}),
            enter_resumed(maps:get(statem_state, Snapshot), Data2);
        none ->
            Data2 = append_initial_messages(Data1),
            emit_run_start(Data2),
            emit_audit(Data2, run_started, #{mode => fresh}),
            save_snapshot(idle, Data2),
            {next_state, idle, Data2}
    end;
handle_event(internal, {finish_resume, PriorState, Restore}, initialising, Data) ->
    Data1 = register_children(Data),
    ok = gakudan_blackboard:restore(Data1#data.blackboard, Restore),
    emit_run_start(Data1),
    emit_audit(Data1, run_resumed, #{mode => supervised, origin => resume_event}),
    enter_resumed(PriorState, Data1);
handle_event(enter, _Old, idle, Data) ->
    notify_awaiters(Data#data.awaiters, Data#data.blackboard),
    {keep_state, Data#data{awaiters = []}};
handle_event(enter, _Old, running, _Data) ->
    keep_state_and_data;
handle_event(cast, {user_message, Msg}, idle, Data) ->
    {ok, _} = gakudan_blackboard:append(Data#data.blackboard, user, Msg),
    dispatch_next_turn(Data);
handle_event(cast, {user_message, Msg}, running, Data) ->
    {ok, _} = gakudan_blackboard:append(Data#data.blackboard, user, Msg),
    keep_state_and_data;
handle_event(info, {turn_done, Pid, Usage}, running, #data{turn_workers = TWs} = Data) when
    is_map_key(Pid, TWs)
->
    TW = maps:get(Pid, TWs),
    emit_turn_stop(Data, TW, ok, undefined),
    demonitor_worker(TW),
    finish_worker(Pid, accumulate_usage(Data, Usage));
handle_event(info, {turn_cancelled, Pid, Usage}, running, #data{turn_workers = TWs} = Data) when
    is_map_key(Pid, TWs)
->
    %% cancel/1 already set cancelling before signalling the worker; this
    %% handler just records the worker's stop, it does not decide run-cancel.
    TW = maps:get(Pid, TWs),
    emit_turn_stop(Data, TW, cancelled, undefined),
    demonitor_worker(TW),
    finish_worker(Pid, accumulate_usage(Data, Usage));
handle_event(info, {turn_failed, Pid, Reason}, running, #data{turn_workers = TWs} = Data) when
    is_map_key(Pid, TWs)
->
    TW = maps:get(Pid, TWs),
    emit_turn_stop(Data, TW, failed, Reason),
    demonitor_worker(TW),
    case {credential_error(Reason), Data#data.stopped} of
        %% Every later turn hits this identically, and an idle run is re-resumed
        %% on every node boot, so end it once instead. Only the first arrival
        %% acts: under fanout all N workers fail the same way.
        {true, undefined} ->
            ?LOG_ERROR(#{
                msg => "run has no usable LLM credential; tearing down instead of idling",
                run_id => Data#data.run_id,
                backend => Data#data.llm_mod
            }),
            append_turn_failure(Data, ~"run stopped: no usable LLM credential", Reason),
            Data1 = Data#data{stopped = no_credentials},
            stop_run_async(Data1, ~"no-credentials teardown failed"),
            {keep_state, Data1};
        {true, _AlreadyStopping} ->
            {keep_state, Data};
        {false, _} ->
            append_turn_failure(Data, ~"turn failed", Reason),
            finish_worker(Pid, Data)
    end;
handle_event(
    info, {'DOWN', _MonRef, process, Pid, Reason}, running, #data{turn_workers = TWs} = Data
) when
    is_map_key(Pid, TWs), Reason =/= normal
->
    TW = maps:get(Pid, TWs),
    emit_turn_stop(Data, TW, failed, Reason),
    append_turn_failure(Data, ~"turn worker crashed", Reason),
    finish_worker(Pid, Data);
handle_event({call, _From}, wait_ready, initialising, _Data) ->
    {keep_state_and_data, [postpone]};
handle_event({call, From}, wait_ready, _State, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};
handle_event({call, From}, status, State, _Data) ->
    {keep_state_and_data, [{reply, From, {ok, State}}]};
handle_event({call, From}, {await, _Timeout}, idle, _Data) ->
    {keep_state_and_data, [{reply, From, {ok, []}}]};
handle_event({call, From}, {await, _Timeout}, awaiting_human, Data) ->
    Entries = gakudan_blackboard:entries(Data#data.blackboard),
    {keep_state_and_data, [{reply, From, {ok, Entries}}]};
handle_event({call, From}, {await, Timeout}, running, Data) ->
    TRef = erlang:start_timer(Timeout, self(), {await_timeout, From}),
    NewAwaiters = [{From, TRef} | Data#data.awaiters],
    {keep_state, Data#data{awaiters = NewAwaiters}};
handle_event(info, {timeout, TRef, {await_timeout, From}}, _State, Data) ->
    NewAwaiters = lists:keydelete(TRef, 2, Data#data.awaiters),
    gen_statem:reply(From, {error, timeout}),
    {keep_state, Data#data{awaiters = NewAwaiters}};
handle_event({call, From}, cancel, running, #data{turn_workers = TWs, cancelling = false} = Data) ->
    maps:foreach(fun(Pid, _Info) -> Pid ! gakudan_llm_cancel end, TWs),
    telemetry:execute(
        [gakudan, run, cancelled],
        #{system_time => erlang:system_time()},
        #{run_id => Data#data.run_id}
    ),
    {keep_state, Data#data{cancelling = true}, [{reply, From, ok}]};
handle_event({call, From}, cancel, _State, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};
handle_event({call, From}, {interrupt, Reason}, State, Data) when
    State =:= idle; State =:= running
->
    Body = interrupt_body(Reason),
    {ok, _} = gakudan_blackboard:append(Data#data.blackboard, system, Body),
    save_snapshot(awaiting_human, Data),
    emit_audit(Data, run_interrupted, #{reason => Reason}),
    {next_state, awaiting_human, Data, [{reply, From, ok}]};
handle_event({call, From}, {interrupt, _Reason}, _State, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_interruptible}}]};
handle_event({call, From}, {resume, Payload}, awaiting_human, Data) ->
    Body = resume_body(Payload),
    {ok, _} = gakudan_blackboard:append(Data#data.blackboard, user, Body),
    save_snapshot(running, Data),
    emit_audit(Data, run_resumed, resume_detail(Payload)),
    {keep_state_and_data, [{reply, From, ok}, {next_event, internal, dispatch_after_resume}]};
handle_event({call, From}, {resume, _Payload}, _State, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_interrupted}}]};
handle_event(internal, dispatch_after_resume, awaiting_human, Data) ->
    dispatch_next_turn(Data);
handle_event(internal, {redispatch_fanout, Agents}, idle, Data) ->
    start_fanout(Agents, Data);
handle_event(info, gakudan_lease_lost, _State, #data{stopped = undefined} = Data) ->
    %% This node's lease was lost to another owner (its save was fenced, or the
    %% heartbeat reported the lease gone). Stop the whole run without writing -
    %% the new owner is running it now. Tear down via the runs supervisor,
    %% asynchronously so we are not blocked terminating our own supervisor.
    telemetry:execute(
        [gakudan, lease, lost],
        #{count => 1},
        #{run_id => Data#data.run_id}
    ),
    stop_run_async(Data, ~"lease-lost teardown failed"),
    {keep_state, Data#data{stopped = lease_lost}};
handle_event(info, gakudan_lease_lost, _State, _Data) ->
    keep_state_and_data;
handle_event(_Type, _Event, _State, _Data) ->
    keep_state_and_data.

terminate(Reason, State, Data) ->
    StopReason = stop_reason(Data, Reason),
    case {StopReason, State} of
        %% Lost-lease teardown: the new owner holds the run; writing here would
        %% be refused anyway. Do not touch the store.
        {lease_lost, _} -> ok;
        {_, awaiting_human} -> ok;
        _ -> save_snapshot(snapshot_status(StopReason), Data)
    end,
    emit_run_stop(Data, StopReason),
    emit_audit_best_effort(Data, run_stopped, #{reason => StopReason}),
    gakudan_registry:unregister(Data#data.run_id),
    ok.

credential_error({_Class, {llm_error, Reason}}) -> gakudan_llm:error_class(Reason) =:= credential;
credential_error(_Other) -> false.

stop_run_async(#data{run_sup = RunSup, run_id = RunId}, FailMsg) ->
    _ = spawn(fun() ->
        case gakudan_runs_sup:stop_run(RunSup) of
            ok ->
                ok;
            {error, Why} ->
                ?LOG_WARNING(#{msg => FailMsg, run_id => RunId, reason => Why})
        end
    end),
    ok.

stop_reason(#data{stopped = undefined}, Reason) -> Reason;
stop_reason(#data{stopped = Stopped}, _Reason) -> Stopped.

snapshot_status(no_credentials) -> failed;
snapshot_status(normal) -> completed;
snapshot_status(shutdown) -> completed;
snapshot_status({shutdown, _}) -> completed;
snapshot_status({budget_exceeded, _}) -> completed;
snapshot_status(Reason) -> {error, Reason}.

dispatch_next_turn(Data) ->
    case check_budget(Data) of
        allow -> route_next_turn(Data);
        {deny, DenyInfo} -> stop_for_budget(Data, DenyInfo)
    end.

route_next_turn(Data) ->
    #data{
        run_id = RunId,
        router_mod = RMod,
        router_state = RState,
        blackboard = BB
    } = Data,
    Entries = gakudan_blackboard:entries(BB),
    case decide_with_telemetry(RunId, RMod, RState, Entries) of
        {next, AgentId, RState1} ->
            start_fanout([AgentId], Data#data{router_state = RState1});
        {fanout, [_ | _] = AgentIds, RState1} ->
            start_fanout(AgentIds, Data#data{router_state = RState1});
        {fanout, [], RState1} ->
            go_idle(Data#data{router_state = RState1});
        {done, RState1} ->
            go_idle(Data#data{router_state = RState1})
    end.

go_idle(Data) ->
    save_snapshot(idle, Data),
    {next_state, idle, Data}.

decide_with_telemetry(RunId, RMod, RState, Entries) ->
    StartMeta = #{run_id => RunId, router => RMod},
    telemetry:span(
        [gakudan, router, decide],
        StartMeta,
        fun() ->
            case RMod:next(RState, Entries) of
                {next, AgentId, _RState1} = Result ->
                    {Result, StartMeta#{decision => {next, AgentId}}};
                {fanout, AgentIds, _RState1} = Result ->
                    {Result, StartMeta#{decision => {fanout, AgentIds}}};
                {done, _RState1} = Result ->
                    {Result, StartMeta#{decision => done}}
            end
        end
    ).

%% Dispatch one parallel round. Each agent runs as its own monitored
%% worker on the same pre-fanout transcript; the router is re-consulted
%% only once every worker has finished. A `{next, Id}` decision is the
%% degenerate fanout of one. See ADR 0007.
start_fanout(AgentIds, Data0) ->
    Base = Data0#data.turn,
    Data = Data0#data{fanout = #{base => Base, agents => AgentIds}},
    save_snapshot(running, Data),
    Workers = maps:from_list(
        [spawn_worker(AgentId, Base + I, Data) || {I, AgentId} <- lists:enumerate(AgentIds)]
    ),
    {next_state, running, Data#data{turn_workers = Workers}}.

spawn_worker(AgentId, TurnNumber, Data) ->
    #data{
        run_id = RunId,
        agents = Agents,
        llm_mod = LMod,
        llm_opts = LOpts,
        blackboard = BB,
        stream = Stream,
        checkpointer = Checkpointer,
        guardrails = Guardrails,
        audit = Audit,
        actor = Actor,
        context = Context
    } = Data,
    {AgentMod, _AgentOpts} = maps:get(AgentId, Agents),
    Self = self(),
    StartTime = erlang:monotonic_time(),
    emit_turn_start(RunId, AgentId, TurnNumber),
    {Pid, MonRef} = spawn_monitor(fun() ->
        try
            case
                gakudan_turn:run(
                    RunId,
                    AgentId,
                    AgentMod,
                    TurnNumber,
                    Checkpointer,
                    LMod,
                    LOpts,
                    BB,
                    Stream,
                    Guardrails,
                    #{audit => Audit, actor => Actor, context => Context}
                )
            of
                {ok, Usage} -> Self ! {turn_done, self(), Usage};
                {cancelled, Usage} -> Self ! {turn_cancelled, self(), Usage}
            end
        catch
            Class:Reason:_St ->
                Self ! {turn_failed, self(), {Class, Reason}}
        end
    end),
    WInfo = #{
        pid => Pid,
        mon_ref => MonRef,
        agent_id => AgentId,
        turn => TurnNumber,
        start_time => StartTime
    },
    {Pid, WInfo}.

finish_worker(Pid, Data) ->
    TWs = maps:remove(Pid, Data#data.turn_workers),
    Data1 = Data#data{turn_workers = TWs},
    case maps:size(TWs) of
        0 -> fanout_complete(Data1);
        _ -> {keep_state, Data1}
    end.

fanout_complete(#data{fanout = #{base := Base, agents := Agents}} = Data) ->
    Data1 = Data#data{turn = Base + length(Agents), fanout = undefined},
    case Data1#data.cancelling of
        true ->
            {ok, _} = gakudan_blackboard:append(Data1#data.blackboard, system, ~"run cancelled"),
            go_idle(Data1#data{cancelling = false});
        false ->
            case should_continue(Data1) of
                true -> dispatch_next_turn(Data1);
                false -> go_idle(Data1)
            end
    end.

demonitor_worker(#{mon_ref := MonRef}) ->
    _ = erlang:demonitor(MonRef, [flush]),
    ok.

append_turn_failure(Data, Prefix, Reason) ->
    Body = iolist_to_binary([Prefix, ": ", io_lib:format("~p", [Reason])]),
    {ok, _} = gakudan_blackboard:append(Data#data.blackboard, system, Body),
    ok.

should_continue(#data{turn = T, max_turns = M}) when T >= M -> false;
should_continue(_) -> true.

build_agents_map(Specs) ->
    maps:from_list([
        case S of
            Mod when is_atom(Mod) -> {Mod:id(), {Mod, #{}}};
            {Mod, Opts} -> {Mod:id(), {Mod, Opts}}
        end
     || S <- Specs
    ]).

agent_id(Mod) when is_atom(Mod) -> Mod:id();
agent_id({Mod, _Opts}) -> Mod:id().

register_children(Data) ->
    Blackboard = find_child(Data#data.run_sup, blackboard),
    Stream = find_child(Data#data.run_sup, stream),
    _ = bind_credential(Data),
    ok = gakudan_registry:register(
        Data#data.run_id, Data#data.run_sup, self(), Blackboard, Stream
    ),
    Data#data{blackboard = Blackboard, stream = Stream}.

load_active_snapshot(#data{checkpointer = undefined}) ->
    none;
load_active_snapshot(#data{checkpointer = Handle, run_id = RunId}) ->
    case gakudan_checkpointer:load_snapshot(Handle, RunId) of
        {ok, #{status := Status} = Snapshot} ->
            case is_active(Status) of
                true -> {ok, Snapshot};
                false -> none
            end;
        {error, _} ->
            none
    end.

is_active(running) -> true;
is_active(idle) -> true;
is_active(awaiting_human) -> true;
is_active(_) -> false.

rehydrate(Data, Snapshot) ->
    #{router_state := RouterState, turn := Turn, last_step := LastStep} = Snapshot,
    Restore = #{
        entries => maps:get(blackboard, Snapshot, []),
        kv => maps:get(kv, Snapshot, #{})
    },
    ok = gakudan_blackboard:restore(Data#data.blackboard, Restore),
    Data#data{
        router_state = RouterState,
        turn = Turn,
        last_step = LastStep,
        fanout = maps:get(fanout, Snapshot, undefined)
    }.

enter_resumed(running, #data{fanout = #{agents := Agents}} = Data) when is_list(Agents) ->
    %% Crashed mid-fanout: re-run the in-flight fanout directly (idempotent
    %% via cached LLM steps + tool results), then the router continues.
    {next_state, idle, Data, [{next_event, internal, {redispatch_fanout, Agents}}]};
enter_resumed(awaiting_human, Data) ->
    {next_state, awaiting_human, Data};
enter_resumed(_State, Data) ->
    {next_state, idle, Data}.

find_child(Sup, Id) ->
    case lists:keyfind(Id, 1, supervisor:which_children(Sup)) of
        {Id, Pid, _, _} when is_pid(Pid) -> Pid;
        _ -> error({child_not_found, Id})
    end.

notify_awaiters([], _) ->
    ok;
notify_awaiters(Awaiters, BB) ->
    Entries = gakudan_blackboard:entries(BB),
    lists:foreach(
        fun({From, TRef}) ->
            _ = erlang:cancel_timer(TRef),
            gen_statem:reply(From, {ok, Entries})
        end,
        Awaiters
    ).

emit_run_start(Data) ->
    telemetry:execute(
        [gakudan, run, start],
        #{system_time => erlang:system_time()},
        #{
            run_id => Data#data.run_id,
            agents => Data#data.agent_ids,
            router => Data#data.router_mod,
            llm_backend => Data#data.llm_mod,
            credential_source => Data#data.credential_source,
            max_turns => Data#data.max_turns
        }
    ).

emit_run_stop(Data, Reason) ->
    Duration = erlang:monotonic_time() - Data#data.start_time,
    telemetry:execute(
        [gakudan, run, stop],
        #{duration => Duration, turns => Data#data.turn},
        #{run_id => Data#data.run_id, reason => Reason}
    ).

emit_turn_start(RunId, AgentId, Turn) ->
    telemetry:execute(
        [gakudan, turn, start],
        #{system_time => erlang:system_time()},
        #{run_id => RunId, agent_id => AgentId, turn => Turn}
    ).

emit_turn_stop(Data, TW, Outcome, Reason) ->
    #{agent_id := AgentId, turn := Turn, start_time := StartTime} = TW,
    Duration = erlang:monotonic_time() - StartTime,
    BaseMeta = #{run_id => Data#data.run_id, agent_id => AgentId, turn => Turn, outcome => Outcome},
    Meta =
        case Outcome of
            failed -> BaseMeta#{reason => Reason};
            _ -> BaseMeta
        end,
    telemetry:execute([gakudan, turn, stop], #{duration => Duration}, Meta).

init_checkpointer(Config) ->
    Spec =
        case maps:get(checkpointer, Config, undefined) of
            undefined -> application:get_env(gakudan, default_checkpointer, undefined);
            S -> S
        end,
    case Spec of
        undefined ->
            undefined;
        {Mod, Opts} ->
            case gakudan_checkpointer:init(Mod, Opts) of
                {ok, Handle} -> Handle;
                {error, Reason} -> error({checkpointer_init_failed, Mod, Reason})
            end
    end.

init_audit(Config) ->
    Spec =
        case maps:get(audit, Config, undefined) of
            undefined -> application:get_env(gakudan, default_audit, undefined);
            S -> S
        end,
    gakudan_audit:init(Spec).

init_budget(Config) ->
    case maps:get(budget, Config, undefined) of
        undefined -> application:get_env(gakudan, default_budget, undefined);
        Ref -> Ref
    end.

init_context(Config) ->
    case maps:get(context, Config, undefined) of
        undefined -> application:get_env(gakudan, default_context, undefined);
        Ref -> Ref
    end.

emit_audit(Data, Type, Detail) ->
    emit_audit(Data, Type, Detail, Data#data.audit).

%% terminate has no action left to gate, so the stop event is always
%% best-effort: a fail_closed sink must never turn a clean stop into a crash.
emit_audit_best_effort(Data, Type, Detail) ->
    emit_audit(Data, Type, Detail, force_log(Data#data.audit)).

emit_audit(Data, Type, Detail, Audit) ->
    Base = #{run_id => Data#data.run_id, actor => Data#data.actor},
    Event = gakudan_audit:event(Type, Base, Detail),
    gakudan_audit:record(Audit, Event).

force_log(undefined) -> undefined;
force_log(Audit) -> Audit#{on_error => log}.

resume_detail(Payload) when is_binary(Payload) ->
    #{mode => human, payload_bytes => byte_size(Payload)};
resume_detail(_Payload) ->
    #{mode => human}.

check_budget(#data{budget = undefined}) ->
    allow;
check_budget(#data{budget = Budget, run_id = RunId, actor = Actor} = Data) ->
    gakudan_budget:check(Budget, budget_usage(Data), #{run_id => RunId, actor => Actor}).

budget_usage(#data{used = Used, turn = Turn}) ->
    #{tokens_in := In, tokens_out := Out} = Used,
    Used#{total_tokens => In + Out, turns => Turn}.

accumulate_usage(#data{used = Used} = Data, Usage) ->
    Data#data{
        used = #{
            tokens_in => maps:get(tokens_in, Used) + maps:get(tokens_in, Usage, 0),
            tokens_out => maps:get(tokens_out, Used) + maps:get(tokens_out, Usage, 0),
            llm_calls => maps:get(llm_calls, Used) + maps:get(llm_calls, Usage, 0)
        }
    }.

stop_for_budget(Data, {Mod, Reason} = DenyInfo) ->
    Body = iolist_to_binary([
        "budget exceeded by ",
        atom_to_binary(Mod),
        ": ",
        io_lib:format("~p", [Reason])
    ]),
    {ok, _} = gakudan_blackboard:append(Data#data.blackboard, system, Body),
    Usage = budget_usage(Data),
    telemetry:execute(
        [gakudan, budget, exceeded],
        #{
            tokens_in => maps:get(tokens_in, Usage),
            tokens_out => maps:get(tokens_out, Usage),
            total_tokens => maps:get(total_tokens, Usage),
            llm_calls => maps:get(llm_calls, Usage)
        },
        #{run_id => Data#data.run_id, budget => Mod, reason => Reason}
    ),
    %% The statem is a permanent child, so a self-stop would be restarted.
    %% Tear the whole run down via the runs supervisor, asynchronously so we
    %% are not blocked terminating our own supervisor. terminate/3 reads the
    %% marker to report the budget reason rather than the shutdown reason.
    stop_run_async(Data, ~"budget stop teardown failed"),
    {keep_state, Data#data{stopped = {budget_exceeded, DenyInfo}}}.

append_initial_messages(#data{config = Config, blackboard = BB} = Data) ->
    Initial = maps:get(initial_messages, Config, []),
    lists:foreach(
        fun(#{role := Role, content := Content}) ->
            {ok, _} = gakudan_blackboard:append(BB, Role, Content)
        end,
        Initial
    ),
    Data.

save_snapshot(_Status, #data{checkpointer = undefined}) ->
    ok;
save_snapshot(Status, #data{checkpointer = Handle} = Data) ->
    #data{
        run_id = RunId,
        config = Config,
        blackboard = BB,
        router_state = RouterState,
        turn = Turn,
        last_step = LastStep
    } = Data,
    BBSnap =
        case BB of
            undefined -> #{entries => [], kv => #{}};
            _ -> gakudan_blackboard:snapshot(BB)
        end,
    Snapshot0 = #{
        run_id => RunId,
        status => Status,
        config => Config,
        last_step => LastStep,
        blackboard => maps:get(entries, BBSnap),
        kv => maps:get(kv, BBSnap),
        router_state => RouterState,
        statem_state => Status,
        turn => Turn,
        fanout => Data#data.fanout,
        updated_at => erlang:system_time(millisecond)
    },
    Snapshot = maybe_add_lease(Snapshot0),
    case gakudan_checkpointer:save_snapshot(Handle, Snapshot) of
        {error, lease_lost} -> self() ! gakudan_lease_lost;
        _ -> ok
    end,
    ok.

%% Read once, here, rather than per dispatch: a per-turn registry call makes
%% every turn depend on one gen_server, and a stall then kills the statem. The
%% credential lives in #data from now on - process-local, so no other run can
%% read it and no caller-supplied key can collide with it. format_status/1
%% keeps it out of crash reports and sys:get_status.
-doc false.
format_status(#{data := #data{} = D} = Status) ->
    Status#{
        data => D#data{
            llm_opts = gakudan_checkpointer:redact_opts(D#data.llm_opts),
            config = gakudan_checkpointer:redact_config(D#data.config),
            agents = redact_agents(D#data.agents)
        }
    };
format_status(Status) ->
    Status.

redact_agents(Agents) ->
    maps:map(
        fun(_Id, {Mod, Opts}) -> {Mod, gakudan_checkpointer:redact_opts(Opts)} end,
        Agents
    ).

bind_credential(#data{run_sup = RunSup, config = Config}) ->
    case maps:get(credential_ref, Config, undefined) of
        undefined -> ok;
        Ref -> gakudan_registry:bind_llm_spec(Ref, RunSup)
    end.

live_llm_spec(Config) ->
    case maps:get(credential_ref, Config, undefined) of
        undefined ->
            maps:get(llm, Config);
        Ref ->
            case gakudan_registry:llm_spec(Ref) of
                {ok, Spec} -> Spec;
                {error, not_found} -> maps:get(llm, Config)
            end
    end.

%% #data holds only redacted opts. The credential is fetched per dispatch so it
%% lives in the short-lived turn worker, never in long-lived gen_statem state
%% that sys:get_state/1 would hand to any process on the node. A vault miss is
%% the legitimate unattended-resume path: fall back and let the backend resolve
%% from the environment.
credential_source(Config) ->
    case maps:get(credential_ref, Config, undefined) of
        undefined -> environment;
        Ref -> stash_state(Ref)
    end.

stash_state(Ref) ->
    case gakudan_registry:llm_spec(Ref) of
        {ok, _} -> caller;
        {error, not_found} -> environment
    end.

maybe_add_lease(Snapshot) ->
    case gakudan_lease:enabled() of
        true ->
            Snapshot#{
                owner => gakudan_lease:owner_id(),
                lease_ttl_ms => gakudan_lease:ttl_ms()
            };
        false ->
            Snapshot
    end.

interrupt_body(Reason) when is_binary(Reason) ->
    <<"interrupted: ", Reason/binary>>;
interrupt_body(Reason) ->
    iolist_to_binary(io_lib:format("interrupted: ~p", [Reason])).

resume_body(Payload) when is_binary(Payload) ->
    Payload;
resume_body(Payload) ->
    iolist_to_binary(io_lib:format("~p", [Payload])).
