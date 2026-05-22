-module(gakudan_llm).
-moduledoc """
LLM backend behaviour. Implementations should return a normalised content list
with `#{type => text, text => ...}` and `#{type => tool_use, id => ..., name => ..., input => ...}`
blocks, plus a `stop_reason` of `end_turn` or `tool_use`.

Backends should include a `usage` map with `input_tokens` and `output_tokens`
where the underlying provider surfaces them. Telemetry consumers report zero
for backends that omit usage.
""".

-export_type([request/0, response/0, content_block/0, usage/0]).

-type content_block() ::
    #{type := text, text := binary()}
    | #{type := tool_use, id := binary(), name := binary(), input := map()}.

-type usage() :: #{
    input_tokens := non_neg_integer(),
    output_tokens := non_neg_integer()
}.

-type request() :: #{
    model := binary(),
    system := binary(),
    tools := [gakudan_tool:spec()],
    messages := [map()]
}.

-type response() :: #{
    stop_reason := end_turn | tool_use | atom(),
    content := [content_block()],
    usage => usage()
}.

-callback complete(request(), Opts :: map()) -> {ok, response()} | {error, term()}.
