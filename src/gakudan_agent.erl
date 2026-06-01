-module(gakudan_agent).
-moduledoc """
Behaviour for an agent role.

Implement this in your own module and pass the module name in `start_run/1`'s
`agents` list. The minimal contract is: identify yourself, declare a system
prompt, declare tools and a model. The library wires the rest.
""".

-export_type([id/0, tool_spec/0, model/0]).

-type id() :: atom().
-type tool_spec() :: gakudan_tool:ref().
-type model() :: binary().

-callback id() -> id().
-callback system_prompt() -> binary().
-callback tools() -> [tool_spec()].
-callback model() -> model().

-doc """
Optional per-request generation options merged into every
`t:gakudan_llm:request/0` this agent issues: `tool_choice`,
`response_format` (a JSON schema for structured output), `max_tokens`,
`temperature`, `stop_sequences`. Backends map them to provider-native
fields. Default: `#{}`.

A `validator => {Module, Schema}` entry (a `t:gakudan_validator:ref/0`) is
consumed by the run rather than the backend: when `response_format` is set
the structured result is validated against it before being written to the
blackboard (under the `structured_output` key) and the transcript. See
[ADR 0017](docs/adr/0017-structured-output-validation.md).
""".
-callback request_options() -> map().

-export([request_options/1]).

-optional_callbacks([request_options/0]).

-doc "Resolve an agent module's optional request_options callback, defaulting to `#{}`.".
-spec request_options(module()) -> map().
request_options(Mod) ->
    case erlang:function_exported(Mod, request_options, 0) of
        true -> Mod:request_options();
        false -> #{}
    end.
