-module(gakudan_llm).
-moduledoc """
LLM backend behaviour. Implementations should return a normalised content list
with `#{type => text, text => ...}` and `#{type => tool_use, id => ..., name => ..., input => ...}`
blocks, plus a `stop_reason` of `end_turn` or `tool_use`.

Backends should include a `usage` map with `input_tokens` and `output_tokens`
where the underlying provider surfaces them. Telemetry consumers report zero
for backends that omit usage.

The optional `stream_call/3` callback adds token-level streaming. See
[ADR 0005](docs/adr/0005-streaming.md). Backends that do not implement
it transparently fall back to `complete/2` wrapped in a single
`text_delta` event.
""".

-export([stream/4]).

-export_type([request/0, response/0, content_block/0, usage/0, stream_event/0, tool_choice/0]).

-type content_block() ::
    #{type := text, text := binary()}
    | #{type := tool_use, id := binary(), name := binary(), input := map()}.

-type usage() :: #{
    input_tokens := non_neg_integer(),
    output_tokens := non_neg_integer(),
    cache_creation_input_tokens => non_neg_integer(),
    cache_read_input_tokens => non_neg_integer()
}.

-type tool_choice() ::
    auto
    | any
    | none
    | {tool, binary()}.

-type request() :: #{
    model := binary(),
    system := binary(),
    tools := [gakudan_tool:spec()],
    messages := [map()],
    tool_choice => tool_choice(),
    response_format => map(),
    max_tokens => pos_integer(),
    temperature => number(),
    stop_sequences => [binary()]
}.

-type response() :: #{
    stop_reason := end_turn | tool_use | atom(),
    content := [content_block()],
    usage => usage()
}.

-type stream_event() ::
    {start, #{model := binary()}}
    | {text_delta, binary()}
    | {tool_use_start, #{id := binary(), name := binary()}}
    | {tool_use_input_delta, #{id := binary(), partial_json := binary()}}
    | {message_delta, #{stop_reason => atom()}}
    | {message_stop, response()}
    | {cancelled, map()}
    | {exception, term()}.

-callback complete(request(), Opts :: map()) -> {ok, response()} | {error, term()}.

-callback stream_call(request(), Opts :: map(), Subscriber :: pid()) ->
    {ok, response()} | {error, term()}.

-optional_callbacks([stream_call/3]).

-doc """
Dispatch a streaming LLM call to `Backend`, sending `t:stream_event/0`
messages to `Subscriber`. Falls back to a synthesised single-delta
stream around `complete/2` if the backend does not implement
`stream_call/3`. `Opts` must carry `stream_request_id => reference()`;
each message arrives as `{gakudan_llm_stream, Ref, Event}`.
""".
-spec stream(module(), request(), map(), pid()) -> {ok, response()} | {error, term()}.
stream(Backend, Request, Opts, Subscriber) ->
    case erlang:function_exported(Backend, stream_call, 3) of
        true ->
            Backend:stream_call(Request, Opts, Subscriber);
        false ->
            synthesize_stream(Backend, Request, Opts, Subscriber)
    end.

synthesize_stream(Backend, Request, Opts, Subscriber) ->
    Ref = maps:get(stream_request_id, Opts),
    Model = maps:get(model, Request),
    Subscriber ! {gakudan_llm_stream, Ref, {start, #{model => Model}}},
    case Backend:complete(Request, Opts) of
        {ok, Response} = Ok ->
            forward_synthetic_events(Subscriber, Ref, Response),
            Subscriber ! {gakudan_llm_stream, Ref, {message_stop, Response}},
            Ok;
        {error, Reason} = Err ->
            Subscriber ! {gakudan_llm_stream, Ref, {exception, Reason}},
            Err
    end.

forward_synthetic_events(Subscriber, Ref, #{content := Content}) ->
    lists:foreach(
        fun
            (#{type := text, text := Text}) ->
                Subscriber ! {gakudan_llm_stream, Ref, {text_delta, Text}};
            (#{type := tool_use, id := Id, name := Name, input := Input}) ->
                Subscriber ! {gakudan_llm_stream, Ref, {tool_use_start, #{id => Id, name => Name}}},
                Json = iolist_to_binary(json:encode(Input)),
                Subscriber !
                    {gakudan_llm_stream, Ref,
                        {tool_use_input_delta, #{id => Id, partial_json => Json}}}
        end,
        Content
    ).
