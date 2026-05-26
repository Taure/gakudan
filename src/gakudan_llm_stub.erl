-module(gakudan_llm_stub).
-moduledoc """
Deterministic LLM stub for tests and offline demos.

Opts:
- `script := [response()]` - dequeued per call; if exhausted, returns `end_turn`
  with empty text.
- `usage := #{input_tokens => N, output_tokens => M}` - attached to every
  response, so tests can drive token-based logic (budgets) deterministically.

A `response()` is `{text, binary()}` or `{tool_use, Name, Input}` or
`{multi, [content_block()]}` for mixing.
""".

-behaviour(gakudan_llm).

-export([complete/2, stream_call/3]).

complete(_Req, Opts) ->
    Pid = script_owner(Opts),
    Next =
        case Pid of
            undefined -> {text, ~""};
            _ -> next_response(Pid)
        end,
    {ok, attach_usage(render(Next), Opts)}.

attach_usage(Resp, #{usage := U}) when is_map(U) -> Resp#{usage => U};
attach_usage(Resp, _Opts) -> Resp.

render({text, T}) ->
    #{stop_reason => end_turn, content => [#{type => text, text => T}]};
render({tool_use, Name, Input}) ->
    Id = iolist_to_binary([~"tu_", integer_to_binary(erlang:unique_integer([positive]))]),
    #{
        stop_reason => tool_use,
        content => [#{type => tool_use, id => Id, name => Name, input => Input}]
    };
render({multi, Blocks}) ->
    Stop = lists:any(
        fun
            (#{type := tool_use}) -> true;
            (_) -> false
        end,
        Blocks
    ),
    #{stop_reason => stop_reason_of(Stop), content => Blocks}.

stop_reason_of(true) -> tool_use;
stop_reason_of(false) -> end_turn.

script_owner(#{script_owner := Pid}) when is_pid(Pid) -> Pid;
script_owner(_) -> undefined.

next_response(Pid) ->
    case gen_server:call(Pid, next, 5000) of
        {ok, R} -> R;
        empty -> {text, ~""}
    end.

-doc """
Streaming variant. If the scripted response is `{stream_chunks, [binary()]}`,
emits one `text_delta` per chunk so tests can assert multi-event behaviour.
Otherwise emits a single `text_delta` carrying the full text, matching the
library's synthetic-fallback semantics. Always finishes with `message_stop`.
""".
-spec stream_call(gakudan_llm:request(), map(), pid()) ->
    {ok, gakudan_llm:response()} | {error, term()}.
stream_call(Req, Opts, Subscriber) ->
    Ref = maps:get(stream_request_id, Opts),
    Model = maps:get(model, Req, ~""),
    Subscriber ! {gakudan_llm_stream, Ref, {start, #{model => Model}}},
    Pid = script_owner(Opts),
    Next =
        case Pid of
            undefined -> {text, ~""};
            _ -> next_response(Pid)
        end,
    case Next of
        {stream_chunks, Chunks} when is_list(Chunks) ->
            lists:foreach(
                fun(C) when is_binary(C) ->
                    Subscriber ! {gakudan_llm_stream, Ref, {text_delta, C}}
                end,
                Chunks
            ),
            Full = iolist_to_binary(Chunks),
            Resp = attach_usage(render({text, Full}), Opts),
            Subscriber ! {gakudan_llm_stream, Ref, {message_stop, Resp}},
            {ok, Resp};
        Other ->
            Resp = attach_usage(render(Other), Opts),
            forward_synthetic(Subscriber, Ref, Resp),
            Subscriber ! {gakudan_llm_stream, Ref, {message_stop, Resp}},
            {ok, Resp}
    end.

forward_synthetic(Subscriber, Ref, #{content := Content}) ->
    lists:foreach(
        fun
            (#{type := text, text := T}) ->
                Subscriber ! {gakudan_llm_stream, Ref, {text_delta, T}};
            (#{type := tool_use, id := Id, name := Name, input := Input}) ->
                Subscriber !
                    {gakudan_llm_stream, Ref, {tool_use_start, #{id => Id, name => Name}}},
                Subscriber !
                    {gakudan_llm_stream, Ref,
                        {tool_use_input_delta, #{
                            id => Id,
                            partial_json => iolist_to_binary(json:encode(Input))
                        }}}
        end,
        Content
    ).
