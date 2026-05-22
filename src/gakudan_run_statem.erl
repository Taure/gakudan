-module(gakudan_run_statem).
-moduledoc false.

-behaviour(gen_statem).

-export([start_link/2, send/2, status/1, stop/1, await/2, wait_ready/1]).
-export([callback_mode/0, init/1, handle_event/4, terminate/3]).

-record(data, {
    run_id :: gakudan:run_id(),
    run_sup :: pid(),
    blackboard :: pid(),
    agents :: #{atom() => {module(), map()}},
    router_mod :: module(),
    router_state :: term(),
    llm_mod :: module(),
    llm_opts :: map(),
    max_turns :: pos_integer(),
    turn = 0 :: non_neg_integer(),
    turn_worker :: undefined | {pid(), reference()},
    awaiters = [] :: [{pid(), reference()}]
}).

start_link(RunSup, Config) ->
    gen_statem:start_link(?MODULE, {RunSup, Config}, []).

-spec send(pid(), binary()) -> ok.
send(Pid, Message) ->
    gen_statem:cast(Pid, {user_message, Message}).

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

init({RunSup, Config}) ->
    process_flag(trap_exit, true),
    #{run_id := RunId, agents := AgentsRaw, router := {RMod, ROpts}, llm := {LMod, LOpts}} = Config,
    MaxTurns = maps:get(max_turns, Config, 16),
    Agents = build_agents_map(AgentsRaw),
    AgentIds = [agent_id(S) || S <- AgentsRaw],
    {ok, RouterState} = RMod:init(ROpts, AgentIds),
    Data = #data{
        run_id = RunId,
        run_sup = RunSup,
        blackboard = undefined,
        agents = Agents,
        router_mod = RMod,
        router_state = RouterState,
        llm_mod = LMod,
        llm_opts = LOpts,
        max_turns = MaxTurns
    },
    {ok, initialising, Data, [{next_event, internal, finish_init}]}.

handle_event(enter, _Old, initialising, _Data) ->
    keep_state_and_data;
handle_event(internal, finish_init, initialising, Data) ->
    Blackboard = find_child(Data#data.run_sup, blackboard),
    ok = gakudan_registry:register(Data#data.run_id, Data#data.run_sup, self(), Blackboard),
    {next_state, idle, Data#data{blackboard = Blackboard}};
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
handle_event(
    info, {turn_complete, Ref, RouterState}, running, #data{turn_worker = {_, Ref}} = Data
) ->
    Data1 = Data#data{
        turn_worker = undefined, router_state = RouterState, turn = Data#data.turn + 1
    },
    case should_continue(Data1) of
        true -> dispatch_next_turn(Data1);
        false -> {next_state, idle, Data1}
    end;
handle_event(info, {turn_failed, Ref, Reason}, running, #data{turn_worker = {_, Ref}} = Data) ->
    {ok, _} = gakudan_blackboard:append(
        Data#data.blackboard,
        system,
        iolist_to_binary(io_lib:format("turn failed: ~p", [Reason]))
    ),
    {next_state, idle, Data#data{turn_worker = undefined}};
handle_event(
    info, {'DOWN', Ref, process, _, Reason}, running, #data{turn_worker = {_, Ref}} = Data
) when
    Reason =/= normal
->
    {ok, _} = gakudan_blackboard:append(
        Data#data.blackboard,
        system,
        iolist_to_binary(io_lib:format("turn worker crashed: ~p", [Reason]))
    ),
    {next_state, idle, Data#data{turn_worker = undefined}};
handle_event({call, _From}, wait_ready, initialising, _Data) ->
    {keep_state_and_data, [postpone]};
handle_event({call, From}, wait_ready, _State, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};
handle_event({call, From}, status, State, _Data) ->
    {keep_state_and_data, [{reply, From, {ok, State}}]};
handle_event({call, From}, {await, _Timeout}, idle, _Data) ->
    {keep_state_and_data, [{reply, From, {ok, []}}]};
handle_event({call, From}, {await, Timeout}, running, Data) ->
    TRef = erlang:start_timer(Timeout, self(), {await_timeout, From}),
    NewAwaiters = [{From, TRef} | Data#data.awaiters],
    {keep_state, Data#data{awaiters = NewAwaiters}};
handle_event(info, {timeout, TRef, {await_timeout, From}}, _State, Data) ->
    NewAwaiters = lists:keydelete(TRef, 2, Data#data.awaiters),
    gen_statem:reply(From, {error, timeout}),
    {keep_state, Data#data{awaiters = NewAwaiters}};
handle_event(_Type, _Event, _State, _Data) ->
    keep_state_and_data.

terminate(_Reason, _State, Data) ->
    gakudan_registry:unregister(Data#data.run_id),
    ok.

dispatch_next_turn(Data) ->
    #data{router_mod = RMod, router_state = RState, blackboard = BB} = Data,
    Entries = gakudan_blackboard:entries(BB),
    case RMod:next(RState, Entries) of
        {next, AgentId, RState1} ->
            start_turn(AgentId, Data#data{router_state = RState1});
        {done, RState1} ->
            {next_state, idle, Data#data{router_state = RState1}}
    end.

start_turn(AgentId, Data) ->
    #data{agents = Agents, llm_mod = LMod, llm_opts = LOpts, blackboard = BB} = Data,
    {AgentMod, AgentOpts} = maps:get(AgentId, Agents),
    Self = self(),
    Ref = make_ref(),
    {Pid, _} = spawn_monitor(fun() ->
        try
            ok = gakudan_turn:run(AgentId, AgentMod, AgentOpts, LMod, LOpts, BB),
            Self ! {turn_complete, Ref, Data#data.router_state}
        catch
            Class:Reason:_St ->
                Self ! {turn_failed, Ref, {Class, Reason}}
        end
    end),
    {next_state, running, Data#data{turn_worker = {Pid, Ref}}}.

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
