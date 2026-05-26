-module(gakudan_audit).
-moduledoc """
Audit behaviour and the chain that records must-not-lose events.

Unlike the telemetry surface (ADR 0001), which is best-effort, an audit
sink is called synchronously before the action proceeds, so a regulated
operator has a durable record of who started a run, which policy
decisions fired, and when a human intervened. See [ADR 0012](docs/adr/0012-audit-logging.md).

A sink is configured per run or as an app-env default, exactly like the
checkpointer:

```erlang
audit => {gakudan_audit_kura, #{repo => my_repo, on_error => fail_closed}}
```

```erlang
{gakudan, [{default_audit, {gakudan_audit_kura, #{repo => my_repo}}}]}
```

With no sink configured every call is a no-op. gakudan ships
`gakudan_audit_kura` as a ready-made sink; the policy and the choice of
sink are yours, this module is only the seam.
""".

-include_lib("kernel/include/logger.hrl").

-export([init/1, record/2, event/3]).

-export_type([handle/0, on_error/0, event/0, event_type/0, spec/0]).

-type spec() :: {module(), Opts :: map()}.
-type on_error() :: log | fail_closed.
-type handle() :: undefined | #{mod := module(), state := term(), on_error := on_error()}.

-type event_type() ::
    run_started
    | run_stopped
    | run_interrupted
    | run_resumed
    | guardrail_allow
    | guardrail_block
    | guardrail_transform.

-type event() :: #{
    type := event_type(),
    run_id := gakudan:run_id(),
    timestamp := integer(),
    actor => map(),
    agent_id => gakudan_agent:id(),
    turn => non_neg_integer(),
    detail => map()
}.

-doc """
Initialise a sink impl. `Opts` may carry `on_error => log | fail_closed`
(default `log`); the rest is passed to the sink's own `init/1`. Returns an
opaque handle threaded into every `record/2` call, or `undefined` when no
sink is configured.
""".
-callback init(Opts :: map()) -> {ok, State :: term()} | {error, term()}.

-doc "Persist a single audit event. Called synchronously, before the action proceeds.".
-callback record(State :: term(), event()) -> ok | {error, term()}.

-doc """
Resolve an audit spec into a handle. `undefined` (no sink) stays a no-op
handle. Errors raised here surface from `start_run/1` so a misconfigured
sink fails fast.
""".
-spec init(undefined | spec()) -> handle().
init(undefined) ->
    undefined;
init({Mod, Opts}) when is_atom(Mod), is_map(Opts) ->
    OnError = maps:get(on_error, Opts, log),
    case Mod:init(Opts) of
        {ok, State} -> #{mod => Mod, state => State, on_error => OnError};
        {error, Reason} -> error({audit_init_failed, Mod, Reason})
    end.

-doc """
Build an event map. `Detail` is merged under `detail`; `run_id`, `actor`,
`agent_id`, and `turn` are read from `Base` when present.
""".
-spec event(event_type(), map(), map()) -> event().
event(Type, Base, Detail) ->
    Core = #{
        type => Type,
        run_id => maps:get(run_id, Base),
        timestamp => erlang:system_time(millisecond),
        detail => Detail
    },
    Optional = maps:with([actor, agent_id, turn], Base),
    maps:merge(Optional, Core).

-doc """
Record an event through the configured sink. A no-op when the handle is
`undefined`. On a sink error the `on_error` policy decides: `log` warns and
continues; `fail_closed` raises so the action does not proceed unrecorded.
""".
-spec record(handle(), event()) -> ok.
record(undefined, _Event) ->
    ok;
record(#{mod := Mod, state := State, on_error := OnError}, Event) ->
    case Mod:record(State, Event) of
        ok ->
            ok;
        {error, Reason} ->
            handle_error(OnError, Mod, Event, Reason)
    end.

handle_error(log, Mod, Event, Reason) ->
    ?LOG_WARNING(#{
        msg => "audit sink write failed",
        sink => Mod,
        event_type => maps:get(type, Event),
        run_id => maps:get(run_id, Event),
        reason => Reason
    }),
    ok;
handle_error(fail_closed, Mod, Event, Reason) ->
    error({audit_write_failed, Mod, maps:get(type, Event), Reason}).
