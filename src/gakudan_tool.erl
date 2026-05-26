-module(gakudan_tool).
-moduledoc """
Tool behaviour. A tool exposes a JSON schema to the LLM and synchronously
runs against an input map.

A tool module can be either **module-only** or **parameterised**:

- *Module-only* tools implement `c:spec/0` and `c:run/1`. Agents declare
  them as plain module names: `tools() -> [my_tool, other_tool].`
- *Parameterised* tools implement `c:spec/1` and `c:run/2`, taking an
  opts map. Agents declare them as `{Module, Opts}` tuples:
  `tools() -> [my_tool, {gakudan_mcp_tool, #{client => x, name => ~"y"}}].`

Parameterised tools let one module wrap many per-instance specs (e.g.
every MCP tool discovered from a single `gakudan_mcp_client`). See
[ADR 0006](docs/adr/0006-mcp-client.md).
""".

-export([resolve/1, resolve_one/1]).

-export_type([spec/0, output/0, ref/0, resolved/0]).

-type spec() :: #{
    name := binary(),
    description := binary(),
    input_schema := map()
}.

-type output() :: {ok, binary() | iolist() | map()} | {error, term()}.

-type ref() :: module() | {module(), Opts :: map()}.

-type resolved() :: #{
    spec := spec(),
    run := fun((map()) -> output()),
    idempotent := boolean()
}.

-callback spec() -> spec().
-callback spec(Opts :: map()) -> spec().
-callback run(Input :: map()) -> output().
-callback run(Input :: map(), Opts :: map()) -> output().

%% Whether the tool's result may be cached and replayed instead of
%% re-run on resume (ADR 0009). Defaults to `true` if not exported. A
%% tool with non-replayable semantics (e.g. "read the current value")
%% returns `false` to always execute.
-callback idempotent() -> boolean().

%% Module-only tools implement spec/0 + run/1; parameterised tools
%% implement spec/1 + run/2. All four are optional at the behaviour
%% level; `resolve_one/1` picks the right pair at runtime.
-optional_callbacks([spec/0, spec/1, run/1, run/2, idempotent/0]).

-doc "Resolve a list of tool refs into `{spec, run}` pairs.".
-spec resolve([ref()]) -> [resolved()].
resolve(Refs) ->
    [resolve_one(R) || R <- Refs].

-doc "Resolve a single tool ref into a `{spec, run}` pair.".
-spec resolve_one(ref()) -> resolved().
resolve_one(Mod) when is_atom(Mod) ->
    #{
        spec => Mod:spec(),
        run => fun(Input) -> Mod:run(Input) end,
        idempotent => is_idempotent(Mod)
    };
resolve_one({Mod, Opts}) when is_atom(Mod), is_map(Opts) ->
    #{
        spec => Mod:spec(Opts),
        run => fun(Input) -> Mod:run(Input, Opts) end,
        idempotent => is_idempotent(Mod)
    }.

is_idempotent(Mod) ->
    case erlang:function_exported(Mod, idempotent, 0) of
        true -> Mod:idempotent();
        false -> true
    end.
