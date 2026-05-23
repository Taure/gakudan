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

-export([complete/2]).
-export([build_body/2, translate_messages/1, translate_tools/1, parse_response/1]).

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
