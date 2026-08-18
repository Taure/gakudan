-module(gakudan).
-moduledoc """
Public façade for `gakudan`, a multi-agent collaboration library for the BEAM.

A *run* is one collaboration session between two or more *agents* coordinated by a
*router*, sharing a *blackboard*. Each component is an OTP behaviour you can swap.

Quickstart:

```erlang
{ok, _Pid, RunId} = gakudan:start_run(#{
    agents => [my_planner, my_coder],
    router => {gakudan_router_handoff, #{start => my_planner}},
    llm    => {gakudan_llm_anthropic, #{model => ~"claude-sonnet-4-6"}}
}),
gakudan:send(RunId, ~"Build a small TCP echo server in Erlang."),
{ok, Transcript} = gakudan:await(RunId, 60_000).
```
""".

-include_lib("kernel/include/logger.hrl").

-export([start_run/1, send/2, status/1, stop/1, await/2, interrupt/2, resume/2, cancel/1]).
-export([subscribe_stream/1, unsubscribe_stream/2]).

-export_type([
    run_id/0,
    run_config/0,
    agent_spec/0,
    router_spec/0,
    llm_spec/0,
    checkpointer_spec/0,
    audit_spec/0,
    budget_spec/0,
    actor/0,
    initial_message/0
]).

-type run_id() :: binary().
-type agent_spec() :: module() | {module(), Opts :: map()}.
-type router_spec() :: {module(), Opts :: map()}.
-type llm_spec() :: {module(), Opts :: map()}.
-type checkpointer_spec() :: {module(), Opts :: map()}.
-type audit_spec() :: {module(), Opts :: map()}.
-type budget_spec() :: gakudan_budget:ref().
-type actor() :: map().
-type initial_message() :: #{role := system | user, content := binary()}.

-type run_config() :: #{
    run_id => run_id(),
    agents := [agent_spec(), ...],
    router := router_spec(),
    llm := llm_spec(),
    max_turns => pos_integer(),
    checkpointer => checkpointer_spec(),
    audit => audit_spec(),
    budget => budget_spec(),
    actor => actor(),
    guardrails => [gakudan_guardrail:ref()],
    context => gakudan_context:ref(),
    fork_from => {run_id(), StepId :: binary()},
    initial_messages => [initial_message()]
}.

-doc """
Start a new run. Returns the supervisor pid and the run id.

With `fork_from => {SourceRunId, StepId}` the new run is rehydrated from
the source run's checkpointed state as of that step and continues under a
fresh run id; the source run is untouched. Forking requires a checkpointer
(in the config or the `default_checkpointer` env). See
[ADR 0021](docs/adr/0021-fork-from-checkpoint.md).
""".
-spec start_run(run_config()) -> {ok, pid(), run_id()} | {error, term()}.
start_run(#{fork_from := ForkPoint} = Config0) ->
    Config = ensure_run_id(maps:remove(fork_from, Config0)),
    ok = warn_unserialisable(Config),
    fork_run(ForkPoint, Config);
start_run(Config0) ->
    Config = ensure_run_id(Config0),
    ok = warn_unserialisable(Config),
    with_stashed_spec(Config, fun gakudan_runs_sup:start_run/1).

%% The vault entry is only ever cleared by the run's own teardown, so a start
%% that never produces a run would strand the credential in ETS for the life of
%% the node. Clear it on any non-{ok,...} outcome, including a raise.
with_stashed_spec(#{run_id := RunId, llm := Spec} = Config, Continue) ->
    ok = gakudan_registry:put_llm_spec(RunId, Spec),
    try Continue(gakudan_checkpointer:redact_config(Config)) of
        {ok, _, _} = Ok ->
            Ok;
        Other ->
            ok = gakudan_registry:forget_llm_spec(RunId),
            Other
    catch
        Class:Reason:St ->
            ok = gakudan_registry:forget_llm_spec(RunId),
            erlang:raise(Class, Reason, St)
    end;
with_stashed_spec(Config, _Continue) ->
    {error, {missing_config_key, llm, maps:get(run_id, Config, undefined)}}.

fork_run(ForkPoint, Config) ->
    case resolve_checkpointer(Config) of
        undefined ->
            {error, no_checkpointer};
        {Mod, Opts} ->
            case gakudan_checkpointer:init(Mod, Opts) of
                {ok, Handle} ->
                    NewRunId = maps:get(run_id, Config),
                    case gakudan_fork:build_snapshot(Handle, ForkPoint, NewRunId) of
                        {ok, Snapshot} ->
                            Merged = maps:merge(
                                maps:get(config, Snapshot), maps:with([llm], Config)
                            ),
                            with_stashed_spec(Merged, fun(Safe) ->
                                gakudan_runs_sup:resume_run(Safe, Snapshot#{config => Safe})
                            end);
                        {error, _} = Err ->
                            Err
                    end;
                {error, _} = Err ->
                    Err
            end
    end.

warn_unserialisable(Config) ->
    case resolve_checkpointer(Config) of
        undefined ->
            ok;
        _ ->
            Persisted = gakudan_checkpointer:redact_config(Config),
            case maps:keys(maps:filter(fun(_K, V) -> holds_fun(V) end, Persisted)) of
                [] ->
                    ok;
                Keys ->
                    ?LOG_WARNING(#{
                        msg =>
                            "run config holds a fun under a checkpointer; "
                            "the snapshot cannot be resumed after a code change",
                        keys => Keys
                    }),
                    ok
            end
    end.

holds_fun(V) when is_function(V) ->
    true;
holds_fun(V) when is_map(V) ->
    lists:any(fun holds_fun/1, maps:keys(V)) orelse lists:any(fun holds_fun/1, maps:values(V));
holds_fun([H | T]) ->
    holds_fun(H) orelse holds_fun(T);
holds_fun(V) when is_tuple(V) ->
    lists:any(fun holds_fun/1, tuple_to_list(V));
holds_fun(_) ->
    false.

resolve_checkpointer(Config) ->
    case maps:get(checkpointer, Config, undefined) of
        undefined -> application:get_env(gakudan, default_checkpointer, undefined);
        Spec -> Spec
    end.

-doc "Send a user message into the run's blackboard, kicking off (or continuing) the loop.".
-spec send(run_id(), binary()) -> ok | {error, not_found}.
send(RunId, Message) when is_binary(RunId), is_binary(Message) ->
    gakudan_run:send(RunId, Message).

-doc "Get current run status: running, idle, completed, or {error, _}.".
-spec status(run_id()) -> {ok, atom()} | {error, not_found}.
status(RunId) ->
    gakudan_run:status(RunId).

-doc "Stop a run (terminates its supervisor and all child agents).".
-spec stop(run_id()) -> ok | {error, not_found}.
stop(RunId) ->
    gakudan_run:stop(RunId).

-doc "Block until the run is idle/completed or `Timeout` elapses.".
-spec await(run_id(), timeout()) ->
    {ok, [gakudan_blackboard:entry()]} | {error, timeout | not_found}.
await(RunId, Timeout) ->
    gakudan_run:await(RunId, Timeout).

-doc """
Pause a run and put it into the `awaiting_human` state. A `system`-role
entry is appended to the blackboard recording the reason. Persisted via
the configured checkpointer; the run survives BEAM restart in this state.
""".
-spec interrupt(run_id(), term()) -> ok | {error, not_found | not_interruptible}.
interrupt(RunId, Reason) ->
    gakudan_run:interrupt(RunId, Reason).

-doc """
Resume a run that is in `awaiting_human`. `Payload` is appended to the
blackboard as a `user`-role entry; the router is then re-consulted and
the loop continues.
""".
-spec resume(run_id(), term()) -> ok | {error, not_found | not_interrupted}.
resume(RunId, Payload) ->
    gakudan_run:resume(RunId, Payload).

-doc """
Cancel a run's in-flight generation. Any LLM stream currently running is
stopped (the backend request is aborted), a `system` entry records the
cancellation, and the run returns to `idle`, ready for new input. A no-op
if nothing is in flight. See [ADR 0014](docs/adr/0014-streaming-cancellation-backpressure.md).
""".
-spec cancel(run_id()) -> ok | {error, not_found}.
cancel(RunId) ->
    gakudan_run:cancel(RunId).

-doc """
Subscribe the calling process to this run's stream channel. The
caller will start receiving `{gakudan_stream, RunId, Event}` messages
for every token delta. See [ADR 0005](docs/adr/0005-streaming.md).
""".
-spec subscribe_stream(run_id()) -> {ok, reference()} | {error, not_found}.
subscribe_stream(RunId) ->
    gakudan_run:subscribe_stream(RunId).

-doc "Unsubscribe a stream reference previously returned by `subscribe_stream/1`.".
-spec unsubscribe_stream(run_id(), reference()) -> ok | {error, not_found}.
unsubscribe_stream(RunId, Ref) ->
    gakudan_run:unsubscribe_stream(RunId, Ref).

ensure_run_id(#{run_id := _} = Config) ->
    Config;
ensure_run_id(Config) ->
    Config#{run_id => new_run_id()}.

new_run_id() ->
    Bytes = crypto:strong_rand_bytes(8),
    iolist_to_binary(io_lib:format("run-~s", [binary:encode_hex(Bytes, lowercase)])).
