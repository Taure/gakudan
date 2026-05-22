-module(gakudan_registry).
-moduledoc false.

-behaviour(gen_server).

-export([start_link/0, register/4, unregister/1, lookup/1, all/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, ?MODULE).

-type entry() :: #{
    run_sup := pid(),
    run_statem := pid(),
    blackboard := pid()
}.

-export_type([entry/0]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec register(gakudan:run_id(), pid(), pid(), pid()) -> ok.
register(RunId, RunSup, RunStatem, Blackboard) ->
    gen_server:call(?MODULE, {register, RunId, RunSup, RunStatem, Blackboard}).

-spec unregister(gakudan:run_id()) -> ok.
unregister(RunId) ->
    gen_server:cast(?MODULE, {unregister, RunId}).

-spec lookup(gakudan:run_id()) -> {ok, entry()} | {error, not_found}.
lookup(RunId) ->
    case ets:lookup(?TAB, RunId) of
        [{_, Entry}] -> {ok, Entry};
        [] -> {error, not_found}
    end.

-spec all() -> [{gakudan:run_id(), entry()}].
all() ->
    ets:tab2list(?TAB).

init([]) ->
    _ = ets:new(?TAB, [named_table, protected, set, {read_concurrency, true}]),
    {ok, #{}}.

handle_call({register, RunId, RunSup, RunStatem, Blackboard}, _From, State) ->
    Entry = #{run_sup => RunSup, run_statem => RunStatem, blackboard => Blackboard},
    true = ets:insert(?TAB, {RunId, Entry}),
    _MonRef = erlang:monitor(process, RunSup),
    NewState = State#{RunSup => RunId},
    {reply, ok, NewState}.

handle_cast({unregister, RunId}, State) ->
    true = ets:delete(?TAB, RunId),
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    case maps:take(Pid, State) of
        {RunId, NewState} ->
            true = ets:delete(?TAB, RunId),
            {noreply, NewState};
        error ->
            {noreply, State}
    end.
