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
-export([put_llm_spec/2, llm_spec/1, bind_llm_spec/2, forget_llm_spec/1, stash_count/0]).
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

-spec put_llm_spec(reference(), term()) -> ok.
put_llm_spec(Ref, Spec) ->
    %% The credential rides in the request, so a registry stall would put it in
    %% a `gen_server:call` timeout exit reason, which a supervised caller logs
    %% in full. Convert that into a reason that carries only the ref.
    try gen_server:call(?MODULE, {put_llm_spec, Ref, Spec}) of
        ok -> ok
    catch
        exit:{Why, {gen_server, call, _}} -> error({registry_unavailable, put_llm_spec, Why})
    end.

-doc "Tie a stashed spec's lifetime to the run supervisor that now owns it.".
-spec bind_llm_spec(reference(), pid()) -> ok.
bind_llm_spec(Ref, RunSup) ->
    ok = gen_server:call(?MODULE, {bind_llm_spec, Ref, RunSup}).

-spec forget_llm_spec(reference()) -> ok.
forget_llm_spec(Ref) ->
    ok = gen_server:call(?MODULE, {forget_llm_spec, Ref}).

-doc "How many credentials the node is holding. Never returns one.".
-spec stash_count() -> non_neg_integer().
stash_count() ->
    case gen_server:call(?MODULE, stash_count) of
        N when is_integer(N) -> N;
        _ -> 0
    end.

-spec llm_spec(reference()) -> {ok, term()} | {error, not_found}.
llm_spec(Ref) ->
    case gen_server:call(?MODULE, {llm_spec, Ref}) of
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

handle_call({put_llm_spec, Ref, Spec}, _From, State) ->
    true = ets:insert(?LLM_TAB, {Ref, Spec, undefined}),
    {reply, ok, State};
handle_call({bind_llm_spec, Ref, RunSup}, _From, State) ->
    case ets:lookup(?LLM_TAB, Ref) of
        [{_, Spec, undefined}] ->
            true = ets:insert(?LLM_TAB, {Ref, Spec, RunSup}),
            {reply, ok, monitor_sup(RunSup, State)};
        _ ->
            {reply, ok, State}
    end;
handle_call(stash_count, _From, State) ->
    {reply, ets:info(?LLM_TAB, size), State};
handle_call({llm_spec, Ref}, _From, State) ->
    Reply =
        case ets:lookup(?LLM_TAB, Ref) of
            [{_, Spec, _}] -> {ok, Spec};
            [] -> {error, not_found}
        end,
    {reply, Reply, State};
handle_call({forget_llm_spec, Ref}, _From, State) ->
    true = ets:delete(?LLM_TAB, Ref),
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

handle_info({'DOWN', _MonRef, process, Pid, _Reason}, State) ->
    %% The run supervisor died, so the run is over: drop its pid entry and any
    %% credential bound to it. This is the only reaper for a started run -
    %% unregister/1 must not do it, because that also runs on a statem restart
    %% under one_for_all and the restarted statem still needs the credential.
    _ = ets:select_delete(?LLM_TAB, [{{'_', '_', Pid}, [], [true]}]),
    case maps:take(Pid, maps:remove({mon, Pid}, State)) of
        {RunId, NewState} ->
            true = ets:delete(?TAB, RunId),
            {noreply, NewState};
        error ->
            {noreply, maps:remove({mon, Pid}, State)}
    end.

monitor_sup(RunSup, State) ->
    case maps:is_key({mon, RunSup}, State) of
        true ->
            State;
        false ->
            MonRef = erlang:monitor(process, RunSup),
            State#{{mon, RunSup} => MonRef}
    end.
