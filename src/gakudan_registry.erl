-module(gakudan_registry).
-moduledoc false.
%% Two tables. ?TAB maps run_id to the run's pids. ?LLM_TAB holds the run's
%% UNREDACTED llm spec: the redacted form travels in run config and therefore
%% into supervisor child specs, crash reports and checkpoints, so the copy
%% carrying the credential has to live somewhere that none of those reach.
%%
%% ?LLM_TAB is private and read through the owner, so no other process can
%% enumerate every live run's credential in one call. It is NOT cleared by
%% unregister/1: that runs on every statem terminate, including a restart
%% under run_sup's one_for_all, and a restarted statem still needs the
%% credential. The 'DOWN' monitor on run_sup owns its lifetime instead - it
%% fires when the run itself ends.

-behaviour(gen_server).

-export([start_link/0, register/5, unregister/1, lookup/1, all/0]).
-export([put_llm_spec/2, llm_spec/1, forget_llm_spec/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, ?MODULE).
-define(LLM_TAB, gakudan_registry_llm).

-type entry() :: #{
    run_sup := pid(),
    run_statem := pid(),
    blackboard := pid(),
    stream := pid()
}.

-export_type([entry/0]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec register(gakudan:run_id(), pid(), pid(), pid(), pid()) -> ok.
register(RunId, RunSup, RunStatem, Blackboard, Stream) ->
    gen_server:call(?MODULE, {register, RunId, RunSup, RunStatem, Blackboard, Stream}).

-spec unregister(gakudan:run_id()) -> ok.
unregister(RunId) ->
    gen_server:cast(?MODULE, {unregister, RunId}).

-spec lookup(gakudan:run_id()) -> {ok, entry()} | {error, not_found}.
lookup(RunId) ->
    case ets:lookup(?TAB, RunId) of
        [{_, Entry}] -> {ok, Entry};
        [] -> {error, not_found}
    end.

-spec put_llm_spec(gakudan:run_id(), term()) -> ok.
put_llm_spec(RunId, Spec) ->
    ok = gen_server:call(?MODULE, {put_llm_spec, RunId, Spec}),
    ok.

-spec forget_llm_spec(gakudan:run_id()) -> ok.
forget_llm_spec(RunId) ->
    ok = gen_server:call(?MODULE, {forget_llm_spec, RunId}),
    ok.

-spec llm_spec(gakudan:run_id()) -> {ok, term()} | {error, not_found}.
llm_spec(RunId) ->
    case gen_server:call(?MODULE, {llm_spec, RunId}) of
        {ok, _} = Ok -> Ok;
        _ -> {error, not_found}
    end.

-spec all() -> [{gakudan:run_id(), entry()}].
all() ->
    ets:tab2list(?TAB).

init([]) ->
    _ = ets:new(?TAB, [named_table, protected, set, {read_concurrency, true}]),
    _ = ets:new(?LLM_TAB, [named_table, private, set]),
    {ok, #{}}.

handle_call({put_llm_spec, RunId, Spec}, _From, State) ->
    true = ets:insert(?LLM_TAB, {RunId, Spec}),
    {reply, ok, State};
handle_call({llm_spec, RunId}, _From, State) ->
    Reply =
        case ets:lookup(?LLM_TAB, RunId) of
            [{_, Spec}] -> {ok, Spec};
            [] -> {error, not_found}
        end,
    {reply, Reply, State};
handle_call({forget_llm_spec, RunId}, _From, State) ->
    true = ets:delete(?LLM_TAB, RunId),
    {reply, ok, State};
handle_call({register, RunId, RunSup, RunStatem, Blackboard, Stream}, _From, State) ->
    Entry = #{
        run_sup => RunSup,
        run_statem => RunStatem,
        blackboard => Blackboard,
        stream => Stream
    },
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
            true = ets:delete(?LLM_TAB, RunId),
            {noreply, NewState};
        error ->
            {noreply, State}
    end.
