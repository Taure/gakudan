-module(gakudan_validator).
-moduledoc """
Validation behaviour for structured LLM output.

When an agent sets a `response_format` schema (see
[ADR 0016](docs/adr/0016-llm-request-options.md)) the backend coerces the
model into producing a structured object. The validator then checks that
object against the schema before it is exposed to the run. See
[ADR 0017](docs/adr/0017-structured-output-validation.md).

A validator is a `{module(), Schema}` ref. The default implementation,
`gakudan_validator_json`, validates a parsed map against a JSON-schema
subset. Bring your own module to validate against anything (an Erlang
record shape, a domain invariant, an external registry).
""".

-export([validate/2]).

-export_type([ref/0, schema/0, result/0, error/0]).

-type schema() :: map().
-type ref() :: {module(), schema()}.
-type error() :: {binary(), term()}.
-type result() :: {ok, term()} | {error, [error()]}.

-doc """
Validate `Value` against `Schema`. Returns `{ok, Value}` (possibly
coerced) on success, or `{error, Errors}` where each error is a
`{Path, Detail}` pair locating the failure.
""".
-callback validate(schema(), Value :: term()) -> result().

-doc "Run a validator ref against a value.".
-spec validate(ref(), term()) -> result().
validate({Mod, Schema}, Value) ->
    Mod:validate(Schema, Value).
