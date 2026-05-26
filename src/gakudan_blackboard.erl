-module(gakudan_blackboard).
-moduledoc """
Shared per-run state. Append-only message log + a small key/value scratchpad.

Subscribers receive `{gakudan_blackboard, RunId, {entry_added, Entry}}` messages.
""".

-behaviour(gen_server).

-export([
    start_link/1,
    append/3,
    entries/1,
    put/3,
    get/2,
    subscribe/1,
    snapshot/1,
    restore/2
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([entry/0, role/0]).

-type role() :: user | system | {agent, atom()}.
-type entry() :: #{
    seq := non_neg_integer(),
    role := role(),
    content := binary() | [map()],
    ts := integer()
}.

-record(state, {
    run_id :: gakudan:run_id(),
    entries_tab :: ets:tid(),
    kv_tab :: ets:tid(),
    seq = 0 :: non_neg_integer(),
    subscribers = #{} :: #{reference() => pid()}
}).

start_link(RunId) ->
    gen_server:start_link(?MODULE, #{run_id => RunId}, []).

-spec append(pid(), role(), binary() | [map()]) -> {ok, entry()}.
append(Pid, Role, Content) ->
    gen_server:call(Pid, {append, Role, Content}).

-spec entries(pid()) -> [entry()].
entries(Pid) ->
    gen_server:call(Pid, entries).

-spec put(pid(), atom(), term()) -> ok.
put(Pid, Key, Value) ->
    gen_server:call(Pid, {put, Key, Value}).

-spec get(pid(), atom()) -> {ok, term()} | {error, not_found}.
get(Pid, Key) ->
    gen_server:call(Pid, {get, Key}).

-spec subscribe(pid()) -> {ok, reference()}.
subscribe(Pid) ->
    gen_server:call(Pid, {subscribe, self()}).

-doc "Capture current entries + kv for persistence.".
-spec snapshot(pid()) -> #{entries := [entry()], kv := #{atom() => term()}}.
snapshot(Pid) ->
    gen_server:call(Pid, snapshot).

-doc "Replace the log + scratchpad with the given entries/kv (used on resume).".
-spec restore(pid(), #{entries := [entry()], kv := #{atom() => term()}}) -> ok.
restore(Pid, #{entries := Entries, kv := Kv}) ->
    gen_server:call(Pid, {restore, Entries, Kv}).

init(#{run_id := RunId}) ->
    EntriesTab = ets:new(entries, [ordered_set, private]),
    KvTab = ets:new(kv, [set, private]),
    {ok, #state{run_id = RunId, entries_tab = EntriesTab, kv_tab = KvTab}}.

handle_call({append, Role, Content}, _From, State) ->
    #state{entries_tab = Tab, seq = Seq, run_id = RunId, subscribers = Subs} = State,
    NewSeq = Seq + 1,
    Entry = #{
        seq => NewSeq,
        role => Role,
        content => Content,
        ts => erlang:system_time(millisecond)
    },
    true = ets:insert(Tab, {NewSeq, Entry}),
    Msg = {gakudan_blackboard, RunId, {entry_added, Entry}},
    maps:foreach(fun(_Ref, Pid) -> Pid ! Msg end, Subs),
    {reply, {ok, Entry}, State#state{seq = NewSeq}};
handle_call(entries, _From, State) ->
    All = [E || {_Seq, E} <- ets:tab2list(State#state.entries_tab)],
    {reply, All, State};
handle_call({put, Key, Value}, _From, State) ->
    true = ets:insert(State#state.kv_tab, {Key, Value}),
    {reply, ok, State};
handle_call({get, Key}, _From, State) ->
    Reply =
        case ets:lookup(State#state.kv_tab, Key) of
            [{_, V}] -> {ok, V};
            [] -> {error, not_found}
        end,
    {reply, Reply, State};
handle_call({subscribe, Pid}, _From, State) ->
    Ref = erlang:monitor(process, Pid),
    Subs = (State#state.subscribers)#{Ref => Pid},
    {reply, {ok, Ref}, State#state{subscribers = Subs}};
handle_call(snapshot, _From, State) ->
    Entries = [E || {_Seq, E} <- ets:tab2list(State#state.entries_tab)],
    Kv = maps:from_list(ets:tab2list(State#state.kv_tab)),
    {reply, #{entries => Entries, kv => Kv}, State};
handle_call({restore, Entries, Kv}, _From, State) ->
    {reply, ok, restore_state(State, Entries, Kv)}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, _Pid, _Reason}, State) ->
    Subs = maps:remove(Ref, State#state.subscribers),
    {noreply, State#state{subscribers = Subs}};
handle_info(_, State) ->
    {noreply, State}.

restore_state(State, Entries, Kv) ->
    lists:foreach(
        fun(#{seq := Seq} = Entry) -> ets:insert(State#state.entries_tab, {Seq, Entry}) end,
        Entries
    ),
    maps:foreach(fun(K, V) -> ets:insert(State#state.kv_tab, {K, V}) end, Kv),
    MaxSeq =
        case Entries of
            [] -> 0;
            _ -> lists:max([Seq || #{seq := Seq} <- Entries])
        end,
    State#state{seq = MaxSeq}.
