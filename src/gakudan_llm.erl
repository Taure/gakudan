-module(gakudan_llm).
-moduledoc """
LLM backend behaviour. Implementations should return a normalised content list
with `#{type => text, text => ...}` and `#{type => tool_use, id => ..., name => ..., input => ...}`
blocks, plus a `stop_reason` of `end_turn` or `tool_use`.
""".

-export_type([request/0, response/0, content_block/0]).

-type content_block() ::
    #{type := text, text := binary()}
    | #{type := tool_use, id := binary(), name := binary(), input := map()}.

-type request() :: #{
    model := binary(),
    system := binary(),
    tools := [gakudan_tool:spec()],
    messages := [map()]
}.

-type response() :: #{
    stop_reason := end_turn | tool_use | atom(),
    content := [content_block()]
}.

-callback complete(request(), Opts :: map()) -> {ok, response()} | {error, term()}.
