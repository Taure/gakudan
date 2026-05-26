-module(gakudan_stream).
-moduledoc """
Per-run streaming pubsub. One gen_server per run, sibling to the
blackboard in `gakudan_run_sup`. Holds a set of subscriber pids
(monitored) and forwards `t:gakudan_llm:stream_event/0` deltas
augmented with run + agent metadata.

Subscribers receive `{gakudan_stream, RunId, Event}` messages, where
`Event` carries the original stream event plus `agent_id` and the
backend's `request_id` ref.

See [ADR 0005](docs/adr/0005-streaming.md).
""".

-behaviour(gen_server).

-export([start_link/1, subscribe/1, unsubscribe/2, publish/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([event/0]).

-type event() :: #{
    run_id := gakudan:run_id(),
    agent_id := atom() | undefined,
    request_id := reference(),
    payload := gakudan_llm:stream_event(),
    dropped => pos_integer()
}.

-record(state, {
    run_id :: gakudan:run_id(),
    subscribers = #{} :: #{reference() => pid()},
    dropped = #{} :: #{reference() => non_neg_integer()},
    max_queue :: pos_integer()
}).

start_link(RunId) ->
    gen_server:start_link(?MODULE, RunId, []).

-doc "Subscribe the calling process to this run's stream channel.".
-spec subscribe(pid()) -> {ok, reference()}.
subscribe(Pid) ->
    gen_server:call(Pid, {subscribe, self()}).

-doc "Unsubscribe a previously-issued reference.".
-spec unsubscribe(pid(), reference()) -> ok.
unsubscribe(Pid, Ref) ->
    gen_server:call(Pid, {unsubscribe, Ref}).

-doc """
Publish a stream event to all subscribers. Called by the turn worker
for each `t:gakudan_llm:stream_event/0` it observes from a backend.
`Meta` carries agent_id + request_id; the pubsub stamps `run_id` and
`payload` to form the final `t:event/0` delivered to subscribers.
""".
-spec publish(pid(), #{agent_id := atom(), request_id := reference()}, gakudan_llm:stream_event()) ->
    ok.
publish(Pid, Meta, Payload) ->
    gen_server:cast(Pid, {publish, Meta, Payload}).

init(RunId) ->
    Max = application:get_env(gakudan, stream_max_queue, 10000),
    {ok, #state{run_id = RunId, max_queue = Max}}.

handle_call({subscribe, Pid}, _From, State) ->
    Ref = erlang:monitor(process, Pid),
    Subs = (State#state.subscribers)#{Ref => Pid},
    {reply, {ok, Ref}, State#state{subscribers = Subs}};
handle_call({unsubscribe, Ref}, _From, State) ->
    _ = erlang:demonitor(Ref, [flush]),
    {reply, ok, forget(Ref, State)}.

handle_cast({publish, Meta0, Payload}, State) ->
    #state{run_id = RunId, subscribers = Subs, dropped = Dropped, max_queue = Max} = State,
    Ctx = {RunId, Meta0, Payload, Max},
    NewDropped = deliver(maps:to_list(Subs), Dropped, Ctx),
    {noreply, State#state{dropped = NewDropped}}.

handle_info({'DOWN', Ref, process, _Pid, _Reason}, State) ->
    {noreply, forget(Ref, State)};
handle_info(_, State) ->
    {noreply, State}.

%% Deliver to each subscriber, shedding load: a subscriber whose mailbox is
%% over the high-water mark is skipped and its drop count incremented; the
%% count is folded into `dropped` on the next event it does receive.
deliver([], Dropped, _Ctx) ->
    Dropped;
deliver([{Ref, Pid} | Rest], Dropped, {RunId, Meta0, Payload, Max} = Ctx) ->
    Prior = maps:get(Ref, Dropped, 0),
    Dropped1 =
        case overloaded(Pid, Max) of
            true ->
                Dropped#{Ref => Prior + 1};
            false ->
                Meta = Meta0#{run_id => RunId, payload => Payload},
                Stamped =
                    case Prior of
                        0 -> Meta;
                        _ -> Meta#{dropped => Prior}
                    end,
                Pid ! {gakudan_stream, RunId, Stamped},
                Dropped#{Ref => 0}
        end,
    deliver(Rest, Dropped1, Ctx).

overloaded(Pid, Max) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, N} when N > Max -> true;
        _ -> false
    end.

forget(Ref, State) ->
    State#state{
        subscribers = maps:remove(Ref, State#state.subscribers),
        dropped = maps:remove(Ref, State#state.dropped)
    }.
