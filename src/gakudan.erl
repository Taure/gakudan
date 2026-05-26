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

-export([start_run/1, send/2, status/1, stop/1, await/2, interrupt/2, resume/2]).
-export([subscribe_stream/1, unsubscribe_stream/2]).

-export_type([
    run_id/0,
    run_config/0,
    agent_spec/0,
    router_spec/0,
    llm_spec/0,
    checkpointer_spec/0,
    initial_message/0
]).

-type run_id() :: binary().
-type agent_spec() :: module() | {module(), Opts :: map()}.
-type router_spec() :: {module(), Opts :: map()}.
-type llm_spec() :: {module(), Opts :: map()}.
-type checkpointer_spec() :: {module(), Opts :: map()}.
-type initial_message() :: #{role := system | user, content := binary()}.

-type run_config() :: #{
    run_id => run_id(),
    agents := [agent_spec(), ...],
    router := router_spec(),
    llm := llm_spec(),
    max_turns => pos_integer(),
    checkpointer => checkpointer_spec(),
    guardrails => [gakudan_guardrail:ref()],
    initial_messages => [initial_message()]
}.

-doc "Start a new run. Returns the supervisor pid and the run id.".
-spec start_run(run_config()) -> {ok, pid(), run_id()} | {error, term()}.
start_run(Config0) ->
    Config = ensure_run_id(Config0),
    gakudan_runs_sup:start_run(Config).

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
