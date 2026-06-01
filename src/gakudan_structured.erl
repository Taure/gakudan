-module(gakudan_structured).
-moduledoc """
Helpers for structured LLM output: extracting the typed value from a
response and validating it against a schema.

When an agent requests `response_format` (see
[ADR 0016](docs/adr/0016-llm-request-options.md)) backends coerce the
model into a structured object in one of two shapes:

- A forced `tool_use` block named `structured_output` whose `input` is the
  object (the Anthropic / Vertex path).
- A `text` block whose body is a JSON document (the Gemini path).

This module recovers the object from either shape and runs an optional
`gakudan_validator` over it. See
[ADR 0017](docs/adr/0017-structured-output-validation.md).
""".

-export([extract/1, validate/2]).

-doc """
Recover the structured object from a response's content blocks. Returns
`{ok, Value}`, or `{error, no_structured_output}` when neither shape is
present (or a JSON text block fails to decode).
""".
-spec extract([gakudan_llm:content_block()]) -> {ok, term()} | {error, no_structured_output}.
extract(Content) ->
    ToolName = gakudan_llm_anthropic:structured_output_tool_name(),
    case [In || #{type := tool_use, name := N, input := In} <- Content, N =:= ToolName] of
        [Value | _] ->
            {ok, Value};
        [] ->
            extract_from_text(Content)
    end.

extract_from_text(Content) ->
    case [T || #{type := text, text := T} <- Content] of
        [Text | _] ->
            try json:decode(Text) of
                Value -> {ok, Value}
            catch
                _:_ -> {error, no_structured_output}
            end;
        [] ->
            {error, no_structured_output}
    end.

-doc """
Validate an extracted value against an optional validator ref. `undefined`
means no validator was configured, so the value passes through unchanged.
""".
-spec validate(undefined | gakudan_validator:ref(), term()) -> gakudan_validator:result().
validate(undefined, Value) ->
    {ok, Value};
validate(Ref, Value) ->
    gakudan_validator:validate(Ref, Value).
