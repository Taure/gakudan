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

-doc """
Optional per-run tool list, receiving the agent's opts from the run config.

`tools/0` is arity-0, so an agent module's tools are fixed at compile time. That
is fine for a stateless tool and wrong for anything that must be scoped per run
or per tenant - a memory namespace, an MCP client name, a per-tenant allow-list.
Declare `tools/1` instead and the opts from `{Module, Opts}` in the run config's
`agents` list are passed through:

```erlang
tools(#{namespace := NS}) ->
    [{my_memory_tool, #{namespace => NS}}].
```

Same widening `m:gakudan_tool` did for `spec/0` -> `spec/1` in
[ADR 0006](docs/adr/0006-mcp-client.md). `tools/1` wins when both are exported.

Scoping must come from the run config, never from LLM-supplied tool input: a
model that can choose its own namespace can read another tenant's data.
""".
-callback tools(Opts :: map()) -> [tool_spec()].

-export([request_options/1, tools/2]).

%% tools/0 and tools/1 are both optional and `tools/2` picks at runtime, the
%% same shape gakudan_tool uses for spec/0 + spec/1 (ADR 0006). An agent with
%% no tools may now declare neither.
-optional_callbacks([request_options/0, tools/0, tools/1]).

-doc "Resolve an agent's tools, preferring the opts-aware `tools/1`.".
-spec tools(module(), map()) -> [tool_spec()].
tools(Mod, Opts) ->
    case erlang:function_exported(Mod, tools, 1) of
        true ->
            Mod:tools(Opts);
        false ->
            case erlang:function_exported(Mod, tools, 0) of
                true -> Mod:tools();
                false -> []
            end
    end.

-doc "Resolve an agent module's optional request_options callback, defaulting to `#{}`.".
-spec request_options(module()) -> map().
request_options(Mod) ->
    case erlang:function_exported(Mod, request_options, 0) of
        true -> Mod:request_options();
        false -> #{}
    end.
