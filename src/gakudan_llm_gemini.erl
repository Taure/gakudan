-module(gakudan_llm_gemini).
-moduledoc """
Google Gemini `generateContent` adapter.

Reads the API key from `Opts` (`api_key => ~"AIza..."`) or, if absent, from the
`GEMINI_API_KEY` env var. Defaults to the v1 REST surface; override with
`api_version => ~"v1beta"` or `base_url => ~"https://..."` in `Opts`.

Tool calls are translated bidirectionally with the gakudan/Anthropic shape:

- Outgoing `tool_use` blocks become Gemini `functionCall` parts.
- Outgoing `tool_result` blocks become Gemini `functionResponse` parts;
  the tool name is recovered from the prior `tool_use` blocks in the same
  conversation (Gemini does not use tool-call ids).
- Incoming `functionCall` parts get a synthesised id so the rest of
  gakudan's machinery works unchanged.

Non-streaming, single candidate. Usage metadata is forwarded so
`tokens_in` / `tokens_out` on `[gakudan, llm, request, stop]` stays
populated.
""".

-behaviour(gakudan_llm).

-export([complete/2, stream_call/3]).
-export([build_body/2, translate_messages/1, translate_tools/1, parse_response/1]).
-export([apply_gemini_event/2, fresh_stream_acc/0, feed_stream_chunk/4, finalise/1]).
-export_type([stream_acc/0]).

-define(DEFAULT_BASE_URL, "https://generativelanguage.googleapis.com").
-define(DEFAULT_API_VERSION, "v1").
-define(DEFAULT_MAX_TOKENS, 4096).
-define(DEFAULT_TIMEOUT, 60_000).

complete(Req, Opts) ->
    case api_key(Opts) of
        undefined -> {error, no_api_key};
        Key -> do_complete(Key, Req, Opts)
    end.

do_complete(ApiKey, Req, Opts) ->
    ok = ensure_inets(),
    Model = maps:get(model, Req),
    Body = build_body(Req, Opts),
    Url = api_url(Model, ApiKey, Opts),
    Headers = [{"content-type", "application/json"}],
    Request = {Url, Headers, "application/json", iolist_to_binary(json:encode(Body))},
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    case httpc:request(post, Request, [{timeout, Timeout}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _RespHdrs, RespBody}} ->
            parse_response(RespBody);
        {ok, {{_, Code, _}, _, RespBody}} ->
            {error, {http_error, Code, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

-doc "Build the JSON-encodable Gemini request body from a gakudan request.".
build_body(#{system := Sys, tools := Tools, messages := Msgs}, Opts) ->
    Base = #{
        contents => translate_messages(Msgs),
        generationConfig => #{
            maxOutputTokens => maps:get(max_tokens, Opts, ?DEFAULT_MAX_TOKENS)
        }
    },
    Base1 =
        case Sys of
            <<>> -> Base;
            _ -> Base#{systemInstruction => #{parts => [#{text => Sys}]}}
        end,
    case Tools of
        [] -> Base1;
        _ -> Base1#{tools => translate_tools(Tools)}
    end.

-doc "Translate gakudan/Anthropic-shaped messages into Gemini `contents`.".
translate_messages(Msgs) ->
    translate_messages(Msgs, #{}, []).

translate_messages([], _IdMap, Acc) ->
    lists:reverse(Acc);
translate_messages([M | Rest], IdMap, Acc) ->
    {Translated, IdMap1} = translate_message(M, IdMap),
    translate_messages(Rest, IdMap1, [Translated | Acc]).

translate_message(#{role := Role, content := Content}, IdMap) ->
    GeminiRole = role_to_gemini(Role),
    {Parts, IdMap1} = translate_content(Content, IdMap),
    {#{role => GeminiRole, parts => Parts}, IdMap1}.

role_to_gemini(user) -> ~"user";
role_to_gemini(assistant) -> ~"model";
role_to_gemini(system) -> ~"user".

translate_content(C, IdMap) when is_binary(C) ->
    {[#{text => C}], IdMap};
translate_content(Blocks, IdMap) when is_list(Blocks) ->
    translate_blocks(Blocks, IdMap, []).

translate_blocks([], IdMap, Acc) ->
    {lists:reverse(Acc), IdMap};
translate_blocks([B | Rest], IdMap, Acc) ->
    {Part, IdMap1} = translate_block(B, IdMap),
    translate_blocks(Rest, IdMap1, [Part | Acc]).

translate_block(#{type := text, text := T}, IdMap) ->
    {#{text => T}, IdMap};
translate_block(#{type := tool_use, id := Id, name := Name, input := In}, IdMap) ->
    {#{functionCall => #{name => Name, args => In}}, IdMap#{Id => Name}};
translate_block(#{type := tool_result, tool_use_id := Id, content := C}, IdMap) ->
    Name = maps:get(Id, IdMap, ~"unknown_tool"),
    Response = #{result => to_text(C)},
    {#{functionResponse => #{name => Name, response => Response}}, IdMap}.

to_text(B) when is_binary(B) -> B;
to_text(L) when is_list(L) -> iolist_to_binary(L);
to_text(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

-doc "Translate gakudan tool specs into Gemini `functionDeclarations`.".
translate_tools([]) ->
    [];
translate_tools(Tools) ->
    [#{functionDeclarations => [translate_tool(T) || T <- Tools]}].

translate_tool(#{name := N, description := D, input_schema := S}) ->
    #{name => N, description => D, parameters => S}.

-doc "Decode a Gemini JSON response into a gakudan/Anthropic-shaped response.".
parse_response(Body) ->
    Decoded = json:decode(Body),
    Candidates = maps:get(~"candidates", Decoded, []),
    {Content, StopReason} =
        case Candidates of
            [] -> {[], end_turn};
            [First | _] -> parse_candidate(First)
        end,
    Base = #{stop_reason => StopReason, content => Content},
    case maps:get(~"usageMetadata", Decoded, undefined) of
        undefined -> {ok, Base};
        Usage -> {ok, Base#{usage => parse_usage(Usage)}}
    end.

parse_candidate(Candidate) ->
    Content = maps:get(~"content", Candidate, #{}),
    Parts = maps:get(~"parts", Content, []),
    Blocks = parse_parts(Parts),
    StopReason = derive_stop_reason(Blocks),
    {Blocks, StopReason}.

parse_parts(Parts) ->
    [parse_part(P) || P <- Parts].

parse_part(#{~"text" := T}) ->
    #{type => text, text => T};
parse_part(#{~"functionCall" := FC}) ->
    Name = maps:get(~"name", FC),
    Args = maps:get(~"args", FC, #{}),
    Id = synth_tool_id(),
    #{type => tool_use, id => Id, name => Name, input => Args};
parse_part(Other) ->
    #{type => text, text => iolist_to_binary(io_lib:format("~p", [Other]))}.

derive_stop_reason(Blocks) ->
    case lists:any(fun(#{type := T}) -> T =:= tool_use end, Blocks) of
        true -> tool_use;
        false -> end_turn
    end.

synth_tool_id() ->
    iolist_to_binary([~"gem_tu_", integer_to_binary(erlang:unique_integer([positive]))]).

parse_usage(Usage) ->
    In = maps:get(~"promptTokenCount", Usage, 0),
    Out = maps:get(~"candidatesTokenCount", Usage, 0),
    #{input_tokens => In, output_tokens => Out}.

api_url(Model, Key, Opts) ->
    Version = maps:get(api_version, Opts, ?DEFAULT_API_VERSION),
    BaseUrl = maps:get(base_url, Opts, ?DEFAULT_BASE_URL),
    ModelStr = to_list(Model),
    binary_to_list(
        iolist_to_binary([
            to_list(BaseUrl),
            "/",
            to_list(Version),
            "/models/",
            ModelStr,
            ":generateContent?key=",
            to_list(Key)
        ])
    ).

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.

api_key(#{api_key := K}) when is_binary(K) -> K;
api_key(_) ->
    case os:getenv("GEMINI_API_KEY") of
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

-type stream_acc() :: #{
    blocks := [block_acc()],
    current_text := undefined | binary(),
    stop_reason := undefined | atom(),
    usage := map(),
    tool_seq := non_neg_integer()
}.

-type block_acc() ::
    #{type := text, text := binary()}
    | #{type := tool_use, id := binary(), name := binary(), input := map()}.

-doc "Stream from Gemini's `streamGenerateContent?alt=sse` endpoint. See [ADR 0005](docs/adr/0005-streaming.md).".
-spec stream_call(gakudan_llm:request(), map(), pid()) ->
    {ok, gakudan_llm:response()} | {error, term()}.
stream_call(Req, Opts, Subscriber) ->
    case api_key(Opts) of
        undefined -> {error, no_api_key};
        Key -> do_stream(Key, Req, Opts, Subscriber)
    end.

do_stream(ApiKey, Req, Opts, Subscriber) ->
    ok = ensure_inets(),
    Model = maps:get(model, Req),
    Body = build_body(Req, Opts),
    Url = stream_api_url(Model, ApiKey, Opts),
    Headers = [{"content-type", "application/json"}, {"accept", "text/event-stream"}],
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
            stream_loop(ReqId, Subscriber, Ref, <<>>, fresh_stream_acc(), Timeout);
        {error, Reason} ->
            Subscriber ! {gakudan_llm_stream, Ref, {exception, Reason}},
            {error, Reason}
    end.

-doc "Fresh streaming accumulator for `feed_stream_chunk/4`.".
-spec fresh_stream_acc() -> stream_acc().
fresh_stream_acc() ->
    #{
        blocks => [],
        current_text => undefined,
        stop_reason => undefined,
        usage => #{input_tokens => 0, output_tokens => 0},
        tool_seq => 0
    }.

-doc """
Feed one chunk of SSE bytes through the streaming pipeline, updating
both the byte-level pending accumulator and the streaming accumulator,
and emitting `gakudan_llm:stream_event()` to the subscriber as side
effects.
""".
-spec feed_stream_chunk(binary(), gakudan_sse:acc(), stream_acc(), {pid(), reference()}) ->
    {gakudan_sse:acc(), stream_acc()}.
feed_stream_chunk(Chunk, Pending, Acc, {Subscriber, Ref}) ->
    {Events, NewPending} = gakudan_sse:parse(Chunk, Pending),
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

dispatch_events([], _Sub, _Ref, Acc) ->
    Acc;
dispatch_events([Event | Rest], Sub, Ref, Acc) ->
    NewAcc = apply_with_forward(Event, Acc, Sub, Ref),
    dispatch_events(Rest, Sub, Ref, NewAcc).

apply_with_forward(Chunk, Acc, Sub, Ref) ->
    %% Each Gemini SSE event is a full GenerateContentResponse-shaped chunk.
    Candidates = maps:get(~"candidates", Chunk, []),
    Acc1 =
        case Candidates of
            [Cand | _] -> apply_candidate(Cand, Acc, Sub, Ref);
            [] -> Acc
        end,
    case maps:get(~"usageMetadata", Chunk, undefined) of
        undefined -> Acc1;
        U -> Acc1#{usage => parse_usage(U)}
    end.

apply_candidate(Cand, Acc, Sub, Ref) ->
    Parts = maps:get(~"parts", maps:get(~"content", Cand, #{}), []),
    Acc1 = lists:foldl(fun(P, A) -> apply_part(P, A, Sub, Ref) end, Acc, Parts),
    case maps:get(~"finishReason", Cand, undefined) of
        undefined ->
            Acc1;
        FR when is_binary(FR) ->
            SR = normalise_finish_reason(FR),
            Sub ! {gakudan_llm_stream, Ref, {message_delta, #{stop_reason => SR}}},
            Acc1#{stop_reason => SR}
    end.

apply_part(#{~"text" := T}, Acc, Sub, Ref) when is_binary(T), T =/= <<>> ->
    Sub ! {gakudan_llm_stream, Ref, {text_delta, T}},
    append_text(Acc, T);
apply_part(#{~"functionCall" := FC}, Acc, Sub, Ref) ->
    Name = maps:get(~"name", FC),
    Args = maps:get(~"args", FC, #{}),
    Acc1 = flush_text(Acc),
    {Id, Acc2} = next_tool_id(Acc1),
    Sub ! {gakudan_llm_stream, Ref, {tool_use_start, #{id => Id, name => Name}}},
    Json = iolist_to_binary(json:encode(Args)),
    Sub !
        {gakudan_llm_stream, Ref, {tool_use_input_delta, #{id => Id, partial_json => Json}}},
    Block = #{type => tool_use, id => Id, name => Name, input => Args},
    Acc2#{blocks => maps:get(blocks, Acc2) ++ [Block]};
apply_part(_Other, Acc, _Sub, _Ref) ->
    Acc.

append_text(#{current_text := undefined} = Acc, T) ->
    Acc#{current_text => T};
append_text(#{current_text := Buf} = Acc, T) ->
    Acc#{current_text => <<Buf/binary, T/binary>>}.

flush_text(#{current_text := undefined} = Acc) ->
    Acc;
flush_text(#{current_text := Buf, blocks := Blocks} = Acc) ->
    Acc#{
        blocks => Blocks ++ [#{type => text, text => Buf}],
        current_text => undefined
    }.

next_tool_id(#{tool_seq := N} = Acc) ->
    Id = iolist_to_binary([~"gem_tu_", integer_to_binary(N + 1)]),
    {Id, Acc#{tool_seq => N + 1}}.

normalise_finish_reason(~"STOP") -> end_turn;
normalise_finish_reason(~"MAX_TOKENS") -> max_tokens;
normalise_finish_reason(~"TOOL_CALL") -> tool_use;
normalise_finish_reason(~"FINISH_REASON_UNSPECIFIED") -> end_turn;
normalise_finish_reason(Other) when is_binary(Other) -> binary_to_atom(Other).

-doc "Apply a decoded Gemini SSE chunk to the streaming accumulator. Pure - no subscriber side effects.".
-spec apply_gemini_event(map(), stream_acc()) -> stream_acc().
apply_gemini_event(Chunk, Acc) ->
    %% Pure variant: ignores subscriber side effects. Useful for unit
    %% tests that exercise accumulator behaviour in isolation.
    Candidates = maps:get(~"candidates", Chunk, []),
    Acc1 =
        case Candidates of
            [Cand | _] -> apply_candidate_pure(Cand, Acc);
            [] -> Acc
        end,
    case maps:get(~"usageMetadata", Chunk, undefined) of
        undefined -> Acc1;
        U -> Acc1#{usage => parse_usage(U)}
    end.

apply_candidate_pure(Cand, Acc) ->
    Parts = maps:get(~"parts", maps:get(~"content", Cand, #{}), []),
    Acc1 = lists:foldl(fun apply_part_pure/2, Acc, Parts),
    case maps:get(~"finishReason", Cand, undefined) of
        undefined -> Acc1;
        FR when is_binary(FR) -> Acc1#{stop_reason => normalise_finish_reason(FR)}
    end.

apply_part_pure(#{~"text" := T}, Acc) when is_binary(T), T =/= <<>> ->
    append_text(Acc, T);
apply_part_pure(#{~"functionCall" := FC}, Acc) ->
    Name = maps:get(~"name", FC),
    Args = maps:get(~"args", FC, #{}),
    Acc1 = flush_text(Acc),
    {Id, Acc2} = next_tool_id(Acc1),
    Block = #{type => tool_use, id => Id, name => Name, input => Args},
    Acc2#{blocks => maps:get(blocks, Acc2) ++ [Block]};
apply_part_pure(_Other, Acc) ->
    Acc.

-doc "Collapse a fully-streamed accumulator into a canonical `gakudan_llm:response()`.".
-spec finalise(stream_acc()) -> gakudan_llm:response().
finalise(Acc) ->
    #{blocks := Blocks0, stop_reason := SR, usage := Usage} = flush_text(Acc),
    Stop =
        case SR of
            undefined ->
                case has_tool_use(Blocks0) of
                    true -> tool_use;
                    false -> end_turn
                end;
            S ->
                S
        end,
    #{stop_reason => Stop, content => Blocks0, usage => Usage}.

has_tool_use(Blocks) ->
    lists:any(fun(#{type := T}) -> T =:= tool_use end, Blocks).

stream_api_url(Model, Key, Opts) ->
    Version = maps:get(api_version, Opts, ?DEFAULT_API_VERSION),
    BaseUrl = maps:get(base_url, Opts, ?DEFAULT_BASE_URL),
    ModelStr = to_list(Model),
    binary_to_list(
        iolist_to_binary([
            to_list(BaseUrl),
            "/",
            to_list(Version),
            "/models/",
            ModelStr,
            ":streamGenerateContent?alt=sse&key=",
            to_list(Key)
        ])
    ).
