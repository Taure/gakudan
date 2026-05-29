-module(gakudan_llm_anthropic).
-moduledoc """
Anthropic Messages API adapter.

Reads the API key from `Opts` (`api_key => ~"sk-ant-..."`) or, if absent, from
the `ANTHROPIC_API_KEY` env var. Defaults to model `claude-sonnet-4-6`,
overridable per-request via the agent's `model/0` callback.

Set `base_url => ~"https://..."` in `Opts` to route through an
Anthropic-compatible gateway or proxy (e.g. an LLM control plane); the backend
appends `/v1/messages`, so point it at the origin + any prefix. Defaults to
`https://api.anthropic.com`. The `x-api-key` header carries whatever key you
pass, so a gateway can authenticate with its own virtual key.

## Prompt caching

The system prompt and tool definitions are automatically marked with
`cache_control: {type: ephemeral}` so Anthropic caches them across calls
within the same 5-minute window. For an agent that runs several turns
back-to-back, this drops the cost of the system + tools portion to ~10%
of the uncached rate on every call after the first.

Anthropic silently ignores the cache hint below model-specific minimum
token thresholds (1024 for Sonnet, 2048 for Haiku), so the hint is
harmless for short prompts.

Cache hits and creations are surfaced in the response `usage` map as
`cache_read_input_tokens` and `cache_creation_input_tokens` (in addition
to the standard `input_tokens` and `output_tokens`).
""".

-behaviour(gakudan_llm).

-export([complete/2, stream_call/3]).
-export([build_body/2, parse_response/1, system_with_cache/1, tools_with_cache/1]).
-export([api_url/1]).
-export([parse_sse/2, apply_anthropic_event/2]).
-export([fresh_stream_acc/0, feed_stream_chunk/4, finalise/1]).
-export_type([sse_acc/0, stream_acc/0]).

-define(DEFAULT_BASE_URL, "https://api.anthropic.com").
-define(MESSAGES_PATH, "/v1/messages").
-define(VERSION, "2023-06-01").
-define(DEFAULT_MAX_TOKENS, 4096).
-define(DEFAULT_TIMEOUT, 60_000).

complete(Req, Opts) ->
    case api_key(Opts) of
        undefined -> {error, no_api_key};
        Key -> do_complete(Key, Req, Opts)
    end.

do_complete(ApiKey, Req, Opts) ->
    ok = ensure_inets(),
    Body = build_body(Req, Opts),
    Headers = [
        {"x-api-key", binary_to_list(ApiKey)},
        {"anthropic-version", ?VERSION}
    ],
    Request = {api_url(Opts), Headers, "application/json", iolist_to_binary(json:encode(Body))},
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    case httpc:request(post, Request, [{timeout, Timeout}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _RespHdrs, RespBody}} ->
            parse_response(RespBody);
        {ok, {{_, Code, _}, _, RespBody}} ->
            {error, {http_error, Code, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

-doc "Build the JSON-encodable Anthropic request body from a gakudan request.".
build_body(#{model := Model, system := Sys, tools := Tools, messages := Msgs}, Opts) ->
    Base = #{
        model => Model,
        system => system_with_cache(Sys),
        messages => normalise_messages(Msgs),
        max_tokens => maps:get(max_tokens, Opts, ?DEFAULT_MAX_TOKENS)
    },
    case Tools of
        [] -> Base;
        _ -> Base#{tools => tools_with_cache(Tools)}
    end.

-doc """
Wrap a non-empty system prompt in a single text block tagged with
`cache_control: {type: ephemeral}`. An empty binary passes through
unchanged.
""".
system_with_cache(<<>>) ->
    <<>>;
system_with_cache(Sys) when is_binary(Sys) ->
    [#{type => text, text => Sys, cache_control => #{type => ephemeral}}].

-doc """
Mark the final tool spec with `cache_control: {type: ephemeral}` so the
whole `tools` array becomes a single cache breakpoint. Empty list
passes through unchanged.
""".
tools_with_cache([]) -> [];
tools_with_cache([Last]) -> [Last#{cache_control => #{type => ephemeral}}];
tools_with_cache([H | T]) -> [H | tools_with_cache(T)].

normalise_messages(Msgs) ->
    [normalise_message(M) || M <- Msgs].

normalise_message(#{role := R, content := C}) when is_binary(C) ->
    #{role => R, content => C};
normalise_message(#{role := R, content := C}) when is_list(C) ->
    #{role => R, content => C}.

-doc "Decode an Anthropic JSON response into a gakudan response.".
parse_response(Body) ->
    Decoded = json:decode(Body),
    Content = maps:get(~"content", Decoded, []),
    Stop = maps:get(~"stop_reason", Decoded, ~"end_turn"),
    Blocks = [parse_block(B) || B <- Content],
    Base = #{
        stop_reason => binary_to_atom(Stop),
        content => Blocks
    },
    case maps:get(~"usage", Decoded, undefined) of
        undefined -> {ok, Base};
        Usage -> {ok, Base#{usage => parse_usage(Usage)}}
    end.

parse_usage(Usage) ->
    Base = #{
        input_tokens => maps:get(~"input_tokens", Usage, 0),
        output_tokens => maps:get(~"output_tokens", Usage, 0)
    },
    Base1 = maybe_put(Base, cache_creation_input_tokens, ~"cache_creation_input_tokens", Usage),
    maybe_put(Base1, cache_read_input_tokens, ~"cache_read_input_tokens", Usage).

maybe_put(Map, OutKey, JsonKey, Source) ->
    case maps:get(JsonKey, Source, undefined) of
        undefined -> Map;
        V -> Map#{OutKey => V}
    end.

parse_block(#{~"type" := ~"text", ~"text" := T}) ->
    #{type => text, text => T};
parse_block(#{~"type" := ~"tool_use", ~"id" := Id, ~"name" := Name, ~"input" := Input}) ->
    #{type => tool_use, id => Id, name => Name, input => Input};
parse_block(Other) ->
    Other.

api_url(Opts) ->
    to_list(maps:get(base_url, Opts, ?DEFAULT_BASE_URL)) ++ ?MESSAGES_PATH.

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.

api_key(#{api_key := K}) when is_binary(K) -> K;
api_key(_) ->
    case os:getenv("ANTHROPIC_API_KEY") of
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

%%% Streaming %%%

-type sse_acc() :: binary().
-type stream_acc() :: #{
    blocks := #{non_neg_integer() => content_block_acc()},
    stop_reason := undefined | atom(),
    usage := map()
}.

-type content_block_acc() ::
    #{type := text, text := binary()}
    | #{type := tool_use, id := binary(), name := binary(), partial_json := binary()}.

-doc "Stream from Anthropic's Messages API. See [ADR 0005](docs/adr/0005-streaming.md).".
-spec stream_call(gakudan_llm:request(), map(), pid()) ->
    {ok, gakudan_llm:response()} | {error, term()}.
stream_call(Req, Opts, Subscriber) ->
    case api_key(Opts) of
        undefined -> {error, no_api_key};
        Key -> do_stream(Key, Req, Opts, Subscriber)
    end.

do_stream(ApiKey, Req, Opts, Subscriber) ->
    ok = ensure_inets(),
    Body = (build_body(Req, Opts))#{stream => true},
    Headers = [
        {"x-api-key", binary_to_list(ApiKey)},
        {"anthropic-version", ?VERSION},
        {"accept", "text/event-stream"}
    ],
    Request = {api_url(Opts), Headers, "application/json", iolist_to_binary(json:encode(Body))},
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    Ref = maps:get(stream_request_id, Opts),
    Subscriber ! {gakudan_llm_stream, Ref, {start, #{model => maps:get(model, Req)}}},
    case
        httpc:request(
            post,
            Request,
            [{timeout, Timeout}],
            [{sync, false}, {stream, self}, {receiver, self()}, {body_format, binary}]
        )
    of
        {ok, ReqId} ->
            stream_loop(ReqId, Subscriber, Ref, <<>>, fresh_stream_acc(), Timeout);
        {error, Reason} ->
            Subscriber ! {gakudan_llm_stream, Ref, {exception, Reason}},
            {error, Reason}
    end.

-doc "Fresh streaming accumulator. Use as the initial state for `feed_stream_chunk/4`.".
-spec fresh_stream_acc() -> stream_acc().
fresh_stream_acc() ->
    #{blocks => #{}, stop_reason => undefined, usage => #{input_tokens => 0, output_tokens => 0}}.

-doc """
Feed one chunk of SSE bytes into the streaming pipeline. Updates the
pending-byte accumulator and the streaming accumulator, emitting
`gakudan_llm:stream_event()` messages to `Subscriber` as side effects.

Returns `{NewPending, NewStreamAcc}`. Call repeatedly with successive
chunks; on `message_stop` arrival call `finalise/1` on the final
accumulator to get the canonical `gakudan_llm:response()`.
""".
-spec feed_stream_chunk(binary(), sse_acc(), stream_acc(), {pid(), reference()}) ->
    {sse_acc(), stream_acc()}.
feed_stream_chunk(Chunk, Pending, Acc, {Subscriber, Ref}) ->
    {Events, NewPending} = parse_sse(Chunk, Pending),
    NewAcc = dispatch_events(Events, Subscriber, Ref, Acc),
    {NewPending, NewAcc}.

stream_loop(ReqId, Subscriber, Ref, Pending, Acc, Timeout) ->
    receive
        {http, {ReqId, stream_start, _Headers}} ->
            stream_loop(ReqId, Subscriber, Ref, Pending, Acc, Timeout);
        {http, {ReqId, stream, Chunk}} ->
            {NewPending, NewAcc} = feed_stream_chunk(Chunk, Pending, Acc, {Subscriber, Ref}),
            stream_loop(ReqId, Subscriber, Ref, NewPending, NewAcc, Timeout);
        {http, {ReqId, stream_end, _Headers}} ->
            Resp = finalise(Acc),
            Subscriber ! {gakudan_llm_stream, Ref, {message_stop, Resp}},
            {ok, Resp};
        {http, {ReqId, {error, Reason}}} ->
            Subscriber ! {gakudan_llm_stream, Ref, {exception, Reason}},
            {error, Reason};
        {http, {ReqId, {{_, Code, _}, _Hdrs, Body}}} when Code >= 400 ->
            Subscriber ! {gakudan_llm_stream, Ref, {exception, {http_error, Code, Body}}},
            {error, {http_error, Code, Body}};
        gakudan_llm_cancel ->
            _ = httpc:cancel_request(ReqId),
            Subscriber ! {gakudan_llm_stream, Ref, {cancelled, #{}}},
            {error, cancelled}
    after Timeout ->
        _ = httpc:cancel_request(ReqId),
        Subscriber ! {gakudan_llm_stream, Ref, {exception, timeout}},
        {error, timeout}
    end.

-doc """
Incremental SSE parser. Delegates to `gakudan_sse:parse/2`; kept as a
re-export for the public surface locked since v0.1 streaming work.
""".
-spec parse_sse(binary(), sse_acc()) -> {[map()], sse_acc()}.
parse_sse(Chunk, Acc) ->
    gakudan_sse:parse(Chunk, Acc).

dispatch_events([], _Sub, _Ref, Acc) ->
    Acc;
dispatch_events([Event | Rest], Sub, Ref, Acc) ->
    NewAcc = apply_anthropic_event(Event, Acc),
    forward(Sub, Ref, Event, NewAcc),
    dispatch_events(Rest, Sub, Ref, NewAcc).

-doc """
Apply a decoded Anthropic SSE event to the streaming accumulator.
Tracks per-index content blocks (text + tool_use), running usage,
and the final stop_reason.
""".
-spec apply_anthropic_event(map(), stream_acc()) -> stream_acc().
apply_anthropic_event(#{~"type" := ~"message_start", ~"message" := Msg}, Acc) ->
    UsageUpdate =
        case maps:get(~"usage", Msg, undefined) of
            undefined -> maps:get(usage, Acc);
            U -> apply_usage_update(maps:get(usage, Acc), U)
        end,
    Acc#{usage => UsageUpdate};
apply_anthropic_event(
    #{~"type" := ~"content_block_start", ~"index" := Idx, ~"content_block" := Block},
    Acc
) ->
    NewBlock =
        case Block of
            #{~"type" := ~"text"} ->
                #{type => text, text => <<>>};
            #{~"type" := ~"tool_use", ~"id" := Id, ~"name" := Name} ->
                #{type => tool_use, id => Id, name => Name, partial_json => <<>>}
        end,
    Blocks = (maps:get(blocks, Acc))#{Idx => NewBlock},
    Acc#{blocks => Blocks};
apply_anthropic_event(
    #{~"type" := ~"content_block_delta", ~"index" := Idx, ~"delta" := Delta},
    Acc
) ->
    Blocks = maps:get(blocks, Acc),
    Block = maps:get(Idx, Blocks),
    Updated = apply_delta(Block, Delta),
    Acc#{blocks => Blocks#{Idx => Updated}};
apply_anthropic_event(#{~"type" := ~"content_block_stop"}, Acc) ->
    Acc;
apply_anthropic_event(#{~"type" := ~"message_delta"} = E, Acc) ->
    Acc1 =
        case maps:get(~"delta", E, #{}) of
            #{~"stop_reason" := SR} when is_binary(SR) ->
                Acc#{stop_reason => binary_to_atom(SR)};
            _ ->
                Acc
        end,
    case maps:get(~"usage", E, undefined) of
        undefined -> Acc1;
        U -> Acc1#{usage => apply_usage_update(maps:get(usage, Acc1), U)}
    end;
apply_anthropic_event(_Other, Acc) ->
    Acc.

apply_delta(#{type := text, text := T} = Block, #{~"type" := ~"text_delta", ~"text" := D}) ->
    Block#{text => <<T/binary, D/binary>>};
apply_delta(
    #{type := tool_use, partial_json := P} = Block,
    #{~"type" := ~"input_json_delta", ~"partial_json" := D}
) ->
    Block#{partial_json => <<P/binary, D/binary>>};
apply_delta(Block, _) ->
    Block.

forward(Sub, Ref, #{~"type" := ~"content_block_start", ~"index" := Idx}, NewAcc) ->
    case maps:get(Idx, maps:get(blocks, NewAcc)) of
        #{type := tool_use, id := Id, name := Name} ->
            _ = Sub ! {gakudan_llm_stream, Ref, {tool_use_start, #{id => Id, name => Name}}},
            ok;
        _ ->
            ok
    end;
forward(Sub, Ref, #{~"type" := ~"content_block_delta", ~"index" := Idx, ~"delta" := Delta}, NewAcc) ->
    Block = maps:get(Idx, maps:get(blocks, NewAcc)),
    case {Block, Delta} of
        {#{type := text}, #{~"type" := ~"text_delta", ~"text" := T}} ->
            _ = Sub ! {gakudan_llm_stream, Ref, {text_delta, T}},
            ok;
        {#{type := tool_use, id := Id}, #{~"type" := ~"input_json_delta", ~"partial_json" := P}} ->
            _ =
                Sub !
                    {gakudan_llm_stream, Ref,
                        {tool_use_input_delta, #{id => Id, partial_json => P}}},
            ok;
        _ ->
            ok
    end;
forward(Sub, Ref, #{~"type" := ~"message_delta"} = E, _NewAcc) ->
    case maps:get(~"delta", E, #{}) of
        #{~"stop_reason" := SR} when is_binary(SR) ->
            _ =
                Sub !
                    {gakudan_llm_stream, Ref,
                        {message_delta, #{stop_reason => binary_to_atom(SR)}}},
            ok;
        _ ->
            ok
    end;
forward(_Sub, _Ref, _Other, _NewAcc) ->
    ok.

apply_usage_update(Existing, Update) ->
    Pairs = [
        {input_tokens, ~"input_tokens"},
        {output_tokens, ~"output_tokens"},
        {cache_creation_input_tokens, ~"cache_creation_input_tokens"},
        {cache_read_input_tokens, ~"cache_read_input_tokens"}
    ],
    lists:foldl(
        fun({OutKey, JsonKey}, Acc) ->
            case maps:get(JsonKey, Update, undefined) of
                undefined -> Acc;
                V -> Acc#{OutKey => V}
            end
        end,
        Existing,
        Pairs
    ).

-doc """
Collapse a fully-streamed accumulator into a canonical
`gakudan_llm:response()`. Blocks are emitted in ascending index
order; tool_use blocks have their accumulated `partial_json` decoded
into the final `input` map.
""".
-spec finalise(stream_acc()) -> gakudan_llm:response().
finalise(#{blocks := Blocks, stop_reason := SR, usage := Usage}) ->
    Indices = lists:sort(maps:keys(Blocks)),
    Content = [block_to_response(maps:get(I, Blocks)) || I <- Indices],
    Stop =
        case SR of
            undefined -> end_turn;
            S -> S
        end,
    #{
        stop_reason => Stop,
        content => Content,
        usage => Usage
    }.

block_to_response(#{type := text, text := T}) ->
    #{type => text, text => T};
block_to_response(#{type := tool_use, id := Id, name := Name, partial_json := P}) ->
    Input =
        case P of
            <<>> -> #{};
            _ -> safe_json_decode(P)
        end,
    #{type => tool_use, id => Id, name => Name, input => Input}.

safe_json_decode(B) ->
    try
        json:decode(B)
    catch
        _:_ -> #{}
    end.
