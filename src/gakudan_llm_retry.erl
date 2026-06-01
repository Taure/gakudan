-module(gakudan_llm_retry).
-moduledoc """
Composable LLM backend that retries a single inner backend on transient
errors with exponential backoff.

It is itself a `gakudan_llm` backend and warps nothing in core. Only
transient failures are retried: HTTP 5xx (`{http_error, Code, _}` with
`Code >= 500`), `timeout`, and connection-level errors. Client errors
(4xx), `no_api_key`, and `cancelled` are returned immediately.

Config:

```erlang
{gakudan_llm_retry, #{
    backend      => {gakudan_llm_anthropic, #{}},
    max_attempts => 3,        %% total tries, default 3
    base_delay   => 200,      %% ms before the first retry, default 200
    max_delay    => 5000      %% ms cap per backoff step, default 5000
}}
```

Backoff is `min(max_delay, base_delay * 2^(attempt-1))`. Compose with
`m:gakudan_llm_fallback` to retry each backend before falling through.

See [ADR 0018](docs/adr/0018-resilient-llm-backends.md).
""".

-behaviour(gakudan_llm).

-include_lib("kernel/include/logger.hrl").

-export([complete/2, stream_call/3]).
-export([transient/1, backoff_delay/3]).

-define(DEFAULT_MAX_ATTEMPTS, 3).
-define(DEFAULT_BASE_DELAY, 200).
-define(DEFAULT_MAX_DELAY, 5000).

-doc "Call the inner backend's `complete/2`, retrying transient errors.".
-spec complete(gakudan_llm:request(), map()) ->
    {ok, gakudan_llm:response()} | {error, term()}.
complete(Req, Opts) ->
    {Mod, MOpts} = maps:get(backend, Opts),
    attempt(Opts, 1, fun() -> Mod:complete(Req, MOpts) end).

-doc "Call the inner backend's stream path, retrying transient errors.".
-spec stream_call(gakudan_llm:request(), map(), pid()) ->
    {ok, gakudan_llm:response()} | {error, term()}.
stream_call(Req, Opts, Subscriber) ->
    {Mod, MOpts} = maps:get(backend, Opts),
    Shared = maps:with([stream_request_id], Opts),
    InnerOpts = maps:merge(MOpts, Shared),
    attempt(Opts, 1, fun() -> gakudan_llm:stream(Mod, Req, InnerOpts, Subscriber) end).

attempt(Opts, Attempt, Call) ->
    Max = maps:get(max_attempts, Opts, ?DEFAULT_MAX_ATTEMPTS),
    case Call() of
        {ok, _} = Ok ->
            Ok;
        {error, Reason} = Err ->
            case transient(Reason) andalso Attempt < Max of
                false ->
                    Err;
                true ->
                    Delay = backoff_delay(Attempt, base_delay(Opts), max_delay(Opts)),
                    ?LOG_WARNING(#{
                        msg => "llm transient error, retrying",
                        attempt => Attempt,
                        max_attempts => Max,
                        delay_ms => Delay,
                        reason => Reason
                    }),
                    timer:sleep(Delay),
                    attempt(Opts, Attempt + 1, Call)
            end
    end.

base_delay(Opts) -> maps:get(base_delay, Opts, ?DEFAULT_BASE_DELAY).
max_delay(Opts) -> maps:get(max_delay, Opts, ?DEFAULT_MAX_DELAY).

-doc "Whether an error reason is transient and worth retrying.".
-spec transient(term()) -> boolean().
transient(timeout) -> true;
transient({http_error, Code, _Body}) when is_integer(Code), Code >= 500 -> true;
transient({failed_connect, _}) -> true;
transient(closed) -> true;
transient(econnrefused) -> true;
transient(_Other) -> false.

-doc "Exponential backoff for `Attempt` (1-based), capped at `MaxDelay` ms.".
-spec backoff_delay(pos_integer(), non_neg_integer(), non_neg_integer()) -> non_neg_integer().
backoff_delay(Attempt, BaseDelay, MaxDelay) ->
    min(MaxDelay, BaseDelay * (1 bsl (Attempt - 1))).
