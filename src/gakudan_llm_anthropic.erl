-module(gakudan_llm_anthropic).
-moduledoc """
Anthropic Messages API adapter.

Reads the API key from `Opts` (`api_key => ~"sk-ant-..."`) or, if absent, from
the `ANTHROPIC_API_KEY` env var. Defaults to model `claude-sonnet-4-6`,
overridable per-request via the agent's `model/0` callback.
""".

-behaviour(gakudan_llm).

-export([complete/2]).

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

build_body(#{model := Model, system := Sys, tools := Tools, messages := Msgs}, Opts) ->
    Base = #{
        model => Model,
        system => Sys,
        messages => normalise_messages(Msgs),
        max_tokens => maps:get(max_tokens, Opts, ?DEFAULT_MAX_TOKENS)
    },
    case Tools of
        [] -> Base;
        _ -> Base#{tools => Tools}
    end.

normalise_messages(Msgs) ->
    [normalise_message(M) || M <- Msgs].

normalise_message(#{role := R, content := C}) when is_binary(C) ->
    #{role => R, content => C};
normalise_message(#{role := R, content := C}) when is_list(C) ->
    #{role => R, content => C}.

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

parse_usage(#{~"input_tokens" := In, ~"output_tokens" := Out}) ->
    #{input_tokens => In, output_tokens => Out};
parse_usage(_) ->
    #{input_tokens => 0, output_tokens => 0}.

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
