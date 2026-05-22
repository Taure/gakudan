-module(gakudan_tool).
-moduledoc """
Tool behaviour. A tool exposes a JSON schema to the LLM (via `spec/0`) and
synchronously runs against an input map (via `run/1`).
""".

-export_type([spec/0, output/0]).

-type spec() :: #{
    name := binary(),
    description := binary(),
    input_schema := map()
}.

-type output() :: {ok, binary() | iolist() | map()} | {error, term()}.

-callback spec() -> spec().
-callback run(Input :: map()) -> output().
