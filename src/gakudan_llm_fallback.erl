-module(gakudan_llm_fallback).
-moduledoc """
Composable LLM backend that tries a list of inner backends in order,
falling through to the next on error.

It is itself a `gakudan_llm` backend, so it slots into a run's `llm` spec
unchanged and warps nothing in core. Each inner backend is an
`t:gakudan:llm_spec/0` (`{Module, Opts}`); on `{error, _}` from one, the
next is tried with the same request. The first `{ok, _}` wins. If every
inner backend errors, the last error is returned.

Config:

```erlang
{gakudan_llm_fallback, #{
    backends => [
        {gakudan_llm_anthropic, #{}},
        {gakudan_llm_vertex, #{project => P, location => L, token_fun => F}}
    ]
}}
```

Compose with `m:gakudan_llm_retry` to add per-backend retry/backoff:
wrap each entry in a retry spec, or wrap the whole fallback in one.

See [ADR 0018](docs/adr/0018-resilient-llm-backends.md).
""".

-behaviour(gakudan_llm).

-include_lib("kernel/include/logger.hrl").

-export([complete/2, stream_call/3]).

-doc "Try each inner backend's `complete/2` in order until one succeeds.".
-spec complete(gakudan_llm:request(), map()) ->
    {ok, gakudan_llm:response()} | {error, term()}.
complete(Req, Opts) ->
    run(backends(Opts), Req, no_backends, fun(Mod, MOpts) ->
        Mod:complete(Req, MOpts)
    end).

-doc "Try each inner backend's stream path in order until one succeeds.".
-spec stream_call(gakudan_llm:request(), map(), pid()) ->
    {ok, gakudan_llm:response()} | {error, term()}.
stream_call(Req, Opts, Subscriber) ->
    run(backends(Opts), Req, no_backends, fun(Mod, MOpts) ->
        gakudan_llm:stream(Mod, Req, merge_stream_opts(Opts, MOpts), Subscriber)
    end).

backends(Opts) ->
    maps:get(backends, Opts, []).

%% The fallback's own opts carry the stream_request_id (and any shared
%% opts the run threads in); each inner backend needs it merged onto its
%% own opts so streaming dispatch and cancellation keep working.
merge_stream_opts(OuterOpts, InnerOpts) ->
    Shared = maps:with([stream_request_id], OuterOpts),
    maps:merge(InnerOpts, Shared).

run([], _Req, LastError, _Call) ->
    {error, LastError};
run([{Mod, MOpts} | Rest], Req, _LastError, Call) ->
    case Call(Mod, MOpts) of
        {ok, _} = Ok ->
            Ok;
        %% A user cancellation is terminal - do not try the next backend.
        {error, cancelled} = Cancelled ->
            Cancelled;
        {error, Reason} = Err ->
            case Rest of
                [] ->
                    Err;
                _ ->
                    ?LOG_WARNING(#{
                        msg => "llm backend failed, falling through",
                        backend => Mod,
                        reason => Reason
                    }),
                    run(Rest, Req, Reason, Call)
            end
    end.
