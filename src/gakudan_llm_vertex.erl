-module(gakudan_llm_vertex).
-moduledoc """
Claude-on-Vertex-AI adapter (GCP).

A thin adapter over `gakudan_llm_anthropic`: Claude on Vertex speaks the
Anthropic Messages API, so this module reuses that module's body builder,
response parser, and streaming pipeline. It supplies only the Vertex
endpoint, the Google bearer auth, and the request-body delta (drop
`model`, add `anthropic_version`). See [ADR 0011](docs/adr/0011-cloud-provider-backends.md).

Config:

```erlang
{gakudan_llm_vertex, #{
    project   => ~"my-gcp-project",
    location  => ~"europe-west1",
    token_fun => fun my_adc:access_token/0   %% or access_token => ~"ya29..."
}}
```

The model id comes from the agent's `c:gakudan_agent:model/0` (e.g.
`~"claude-sonnet-4-5@20250929"`). Auth is the host's responsibility:
provide `token_fun` (a `fun/0` returning a fresh token, recommended) or a
static `access_token`, or set `GOOGLE_VERTEX_TOKEN`. gakudan does not
bundle a Google ADC/OAuth implementation.
""".

-behaviour(gakudan_llm).

-export([complete/2, stream_call/3]).
-export([vertex_body/2, endpoint/4]).

-define(ANTHROPIC_VERSION, ~"vertex-2023-10-16").
-define(DEFAULT_TIMEOUT, 60_000).

complete(Req, Opts) ->
    case config(Opts) of
        {error, _} = Err -> Err;
        {ok, {Project, Location, Token}} -> do_complete(Req, Opts, Project, Location, Token)
    end.

do_complete(#{model := Model} = Req, Opts, Project, Location, Token) ->
    ok = ensure_inets(),
    Url = endpoint(Project, Location, Model, "rawPredict"),
    Body = vertex_body(Req, Opts),
    Request = {Url, auth_headers(Token), "application/json", iolist_to_binary(json:encode(Body))},
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    case httpc:request(post, Request, [{timeout, Timeout}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _RespHdrs, RespBody}} ->
            gakudan_llm_anthropic:parse_response(RespBody);
        {ok, {{_, Code, _}, _, RespBody}} ->
            {error, {http_error, Code, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

-doc "Stream from Claude on Vertex. See [ADR 0005](docs/adr/0005-streaming.md).".
-spec stream_call(gakudan_llm:request(), map(), pid()) ->
    {ok, gakudan_llm:response()} | {error, term()}.
stream_call(Req, Opts, Subscriber) ->
    case config(Opts) of
        {error, _} = Err ->
            Err;
        {ok, {Project, Location, Token}} ->
            do_stream(Req, Opts, Project, Location, Token, Subscriber)
    end.

do_stream(#{model := Model} = Req, Opts, Project, Location, Token, Subscriber) ->
    ok = ensure_inets(),
    Url = endpoint(Project, Location, Model, "streamRawPredict"),
    Body = (vertex_body(Req, Opts))#{stream => true},
    Headers = [{"accept", "text/event-stream"} | auth_headers(Token)],
    Request = {Url, Headers, "application/json", iolist_to_binary(json:encode(Body))},
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    Ref = maps:get(stream_request_id, Opts),
    Subscriber ! {gakudan_llm_stream, Ref, {start, #{model => Model}}},
    case
        httpc:request(
            post,
            Request,
            [{timeout, Timeout}],
            [{sync, false}, {stream, self}, {receiver, self()}, {body_format, binary}]
        )
    of
        {ok, ReqId} ->
            stream_loop(
                ReqId, Subscriber, Ref, <<>>, gakudan_llm_anthropic:fresh_stream_acc(), Timeout
            );
        {error, Reason} ->
            Subscriber ! {gakudan_llm_stream, Ref, {exception, Reason}},
            {error, Reason}
    end.

stream_loop(ReqId, Sub, Ref, Pending, Acc, Timeout) ->
    receive
        {http, {ReqId, stream_start, _Headers}} ->
            stream_loop(ReqId, Sub, Ref, Pending, Acc, Timeout);
        {http, {ReqId, stream, Chunk}} ->
            {NewPending, NewAcc} = gakudan_llm_anthropic:feed_stream_chunk(
                Chunk, Pending, Acc, {Sub, Ref}
            ),
            stream_loop(ReqId, Sub, Ref, NewPending, NewAcc, Timeout);
        {http, {ReqId, stream_end, _Headers}} ->
            Resp = gakudan_llm_anthropic:finalise(Acc),
            Sub ! {gakudan_llm_stream, Ref, {message_stop, Resp}},
            {ok, Resp};
        {http, {ReqId, {error, Reason}}} ->
            Sub ! {gakudan_llm_stream, Ref, {exception, Reason}},
            {error, Reason};
        {http, {ReqId, {{_, Code, _}, _Hdrs, Body}}} when Code >= 400 ->
            Sub ! {gakudan_llm_stream, Ref, {exception, {http_error, Code, Body}}},
            {error, {http_error, Code, Body}}
    after Timeout ->
        _ = httpc:cancel_request(ReqId),
        Sub ! {gakudan_llm_stream, Ref, {exception, timeout}},
        {error, timeout}
    end.

-doc """
The Anthropic request body adapted for Vertex: the `model` key is dropped
(it lives in the URL) and `anthropic_version` is added.
""".
-spec vertex_body(gakudan_llm:request(), map()) -> map().
vertex_body(Req, Opts) ->
    Body = gakudan_llm_anthropic:build_body(Req, Opts),
    (maps:remove(model, Body))#{anthropic_version => ?ANTHROPIC_VERSION}.

-doc "Build the Vertex `publishers/anthropic` prediction URL for `Action`.".
-spec endpoint(binary(), binary(), binary(), string()) -> string().
endpoint(Project, Location, Model, Action) ->
    lists:flatten(
        io_lib:format(
            "https://~s-aiplatform.googleapis.com/v1/projects/~s/locations/~s"
            "/publishers/anthropic/models/~s:~s",
            [Location, Project, Location, Model, Action]
        )
    ).

auth_headers(Token) ->
    [{"authorization", "Bearer " ++ binary_to_list(Token)}].

config(Opts) ->
    case {project(Opts), location(Opts), token(Opts)} of
        {undefined, _, _} -> {error, {bad_config, missing_project}};
        {_, undefined, _} -> {error, {bad_config, missing_location}};
        {_, _, undefined} -> {error, {bad_config, missing_access_token}};
        {Project, Location, Token} -> {ok, {Project, Location, Token}}
    end.

project(#{project := P}) when is_binary(P) -> P;
project(_) -> undefined.

location(#{location := L}) when is_binary(L) -> L;
location(_) -> undefined.

token(#{token_fun := F}) when is_function(F, 0) -> F();
token(#{access_token := T}) when is_binary(T) -> T;
token(_) ->
    case os:getenv("GOOGLE_VERTEX_TOKEN") of
        false -> undefined;
        "" -> undefined;
        Val -> list_to_binary(Val)
    end.

ensure_inets() ->
    case inets:start() of
        ok -> ok;
        {error, {already_started, _}} -> ok
    end,
    case ssl:start() of
        ok -> ok;
        {error, {already_started, _}} -> ok
    end.
