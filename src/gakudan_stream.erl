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
    payload := gakudan_llm:stream_event()
}.

-record(state, {
    run_id :: gakudan:run_id(),
    subscribers = #{} :: #{reference() => pid()}
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
    {ok, #state{run_id = RunId}}.

handle_call({subscribe, Pid}, _From, State) ->
    Ref = erlang:monitor(process, Pid),
    Subs = (State#state.subscribers)#{Ref => Pid},
    {reply, {ok, Ref}, State#state{subscribers = Subs}};
handle_call({unsubscribe, Ref}, _From, State) ->
    _ = erlang:demonitor(Ref, [flush]),
    Subs = maps:remove(Ref, State#state.subscribers),
    {reply, ok, State#state{subscribers = Subs}}.

handle_cast({publish, #{request_id := ReqId} = Meta0, Payload}, State) ->
    Meta = Meta0#{run_id => State#state.run_id, payload => Payload},
    Msg = {gakudan_stream, State#state.run_id, Meta},
    maps:foreach(fun(_Ref, Pid) -> Pid ! Msg end, State#state.subscribers),
    _ = ReqId,
    {noreply, State}.

handle_info({'DOWN', Ref, process, _Pid, _Reason}, State) ->
    Subs = maps:remove(Ref, State#state.subscribers),
    {noreply, State#state{subscribers = Subs}};
handle_info(_, State) ->
    {noreply, State}.
