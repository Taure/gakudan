-module(gakudan_llm_retry).
-moduledoc """
Composable LLM backend that retries a single inner backend on transient
errors with exponential backoff.

It is itself a `gakudan_llm` backend and warps nothing in core. Only
transient failures are retried: HTTP 429, HTTP 5xx (`{http_error, Code, _}`
with `Code >= 500`), `timeout`, and connection-level errors. Other client
errors (4xx), `no_api_key`, and `cancelled` are returned immediately.

429 is retried on a **tighter budget** than 5xx - `max_rate_limit_attempts`,
default 2 - because retrying is offered load into a limiter that has just
said stop, and the multipliers compound across router iterations, fanout
agents and fallback backends. The provider's `Retry-After` header is not
honoured because `{http_error, Code, Body}` carries no headers; surfacing
them is a change to the backend error contract, not to this module.

Backoff is jittered (half the computed delay plus a random half) so that
fanout workers which failed together do not retry in lockstep.

The backoff wait is cancellable: a `gakudan_llm_cancel` message arriving
while waiting ends the call with `{error, cancelled}` instead of being
deferred until the next attempt.

Config:

```erlang
{gakudan_llm_retry, #{
    backend      => {gakudan_llm_anthropic, #{}},
    max_attempts => 3,        %% total tries, default 3
    max_rate_limit_attempts => 2,  %% total tries on HTTP 429, default 2
    base_delay   => 200,      %% ms before the first retry, default 200
    max_delay    => 5000      %% ms cap per backoff step, default 5000
}}
```

Backoff is `min(max_delay, base_delay * 2^(attempt-1))`, then jittered.
Compose with
`m:gakudan_llm_fallback` to retry each backend before falling through.

See [ADR 0018](docs/adr/0018-resilient-llm-backends.md).
""".

-behaviour(gakudan_llm).

-include_lib("kernel/include/logger.hrl").

-export([complete/2, stream_call/3]).
-export([transient/1, backoff_delay/3]).

-define(DEFAULT_MAX_ATTEMPTS, 3).
-define(DEFAULT_MAX_RATE_LIMIT_ATTEMPTS, 2).
-define(DEFAULT_BASE_DELAY, 200).
-define(DEFAULT_MAX_DELAY, 5000).

-doc "Call the inner backend's `complete/2`, retrying transient errors.".
-spec complete(gakudan_llm:request(), map()) ->
    {ok, gakudan_llm:response()} | {error, term()}.
complete(Req, Opts) ->
    {Mod, MOpts} = maps:get(backend, Opts),
    attempt(Opts, 1, fun() -> Mod:complete(Req, MOpts) end, undefined).

-doc "Call the inner backend's stream path, retrying transient errors.".
-spec stream_call(gakudan_llm:request(), map(), pid()) ->
    {ok, gakudan_llm:response()} | {error, term()}.
stream_call(Req, Opts, Subscriber) ->
    {Mod, MOpts} = maps:get(backend, Opts),
    Shared = maps:with([stream_request_id], Opts),
    InnerOpts = maps:merge(MOpts, Shared),
    Ref = maps:get(stream_request_id, Opts),
    attempt(
        Opts,
        1,
        fun() -> gakudan_llm:stream(Mod, Req, InnerOpts, Subscriber) end,
        {Subscriber, Ref}
    ).

attempt(Opts, Attempt, Call, Stream) ->
    case Call() of
        {ok, _} = Ok ->
            Ok;
        {error, Reason} = Err ->
            Max = max_attempts_for(Reason, Opts),
            case transient(Reason) andalso Attempt < Max of
                false ->
                    Err;
                true ->
                    Delay = jitter(backoff_delay(Attempt, base_delay(Opts), max_delay(Opts))),
                    ?LOG_WARNING(#{
                        msg => "llm transient error, retrying",
                        attempt => Attempt,
                        max_attempts => Max,
                        delay_ms => Delay,
                        reason => Reason
                    }),
                    case wait(Delay) of
                        cancelled ->
                            notify_cancelled(Stream),
                            {error, cancelled};
                        ok ->
                            attempt(Opts, Attempt + 1, Call, Stream)
                    end
            end
    end.

wait(Delay) ->
    receive
        gakudan_llm_cancel -> cancelled
    after Delay -> ok
    end.

notify_cancelled(undefined) ->
    ok;
notify_cancelled({Subscriber, Ref}) ->
    Subscriber ! {gakudan_llm_stream, Ref, {cancelled, #{}}},
    ok.

max_attempts_for({http_error, 429, _}, Opts) ->
    maps:get(max_rate_limit_attempts, Opts, ?DEFAULT_MAX_RATE_LIMIT_ATTEMPTS);
max_attempts_for(_Reason, Opts) ->
    maps:get(max_attempts, Opts, ?DEFAULT_MAX_ATTEMPTS).

jitter(Delay) when Delay < 2 -> Delay;
jitter(Delay) -> Delay div 2 + rand:uniform(Delay div 2).

base_delay(Opts) -> maps:get(base_delay, Opts, ?DEFAULT_BASE_DELAY).
max_delay(Opts) -> maps:get(max_delay, Opts, ?DEFAULT_MAX_DELAY).

-doc "Whether an error reason is transient and worth retrying.".
-spec transient(term()) -> boolean().
transient(Reason) -> gakudan_llm:error_class(Reason) =:= transient.

-doc "Exponential backoff for `Attempt` (1-based), capped at `MaxDelay` ms.".
-spec backoff_delay(pos_integer(), non_neg_integer(), non_neg_integer()) -> non_neg_integer().
backoff_delay(Attempt, BaseDelay, MaxDelay) ->
    min(MaxDelay, BaseDelay * (1 bsl (Attempt - 1))).
