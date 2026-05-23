-module(gakudan_llm_anthropic).
-moduledoc """
Anthropic Messages API adapter.

Reads the API key from `Opts` (`api_key => ~"sk-ant-..."`) or, if absent, from
the `ANTHROPIC_API_KEY` env var. Defaults to model `claude-sonnet-4-6`,
overridable per-request via the agent's `model/0` callback.

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

-export([complete/2]).
-export([build_body/2, parse_response/1, system_with_cache/1, tools_with_cache/1]).

-define(API_URL, "https://api.anthropic.com/v1/messages").
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
    Request = {?API_URL, Headers, "application/json", iolist_to_binary(json:encode(Body))},
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
