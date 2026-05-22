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

-export([start_run/1, send/2, status/1, stop/1, await/2]).

-export_type([run_id/0, run_config/0, agent_spec/0, router_spec/0, llm_spec/0]).

-type run_id() :: binary().
-type agent_spec() :: module() | {module(), Opts :: map()}.
-type router_spec() :: {module(), Opts :: map()}.
-type llm_spec() :: {module(), Opts :: map()}.

-type run_config() :: #{
    run_id => run_id(),
    agents := [agent_spec(), ...],
    router := router_spec(),
    llm := llm_spec(),
    max_turns => pos_integer()
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

ensure_run_id(#{run_id := _} = Config) ->
    Config;
ensure_run_id(Config) ->
    Config#{run_id => new_run_id()}.

new_run_id() ->
    Bytes = crypto:strong_rand_bytes(8),
    iolist_to_binary(io_lib:format("run-~s", [binary:encode_hex(Bytes, lowercase)])).
