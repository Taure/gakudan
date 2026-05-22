-module(gakudan_llm_stub).
-moduledoc """
Deterministic LLM stub for tests and offline demos.

Opts:
- `script := [response()]` - dequeued per call; if exhausted, returns `end_turn`
  with empty text.

A `response()` is `{text, binary()}` or `{tool_use, Name, Input}` or
`{multi, [content_block()]}` for mixing.
""".

-behaviour(gakudan_llm).

-export([complete/2]).

complete(_Req, Opts) ->
    Pid = script_owner(Opts),
    Next =
        case Pid of
            undefined -> {text, ~""};
            _ -> next_response(Pid)
        end,
    {ok, render(Next)}.

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
