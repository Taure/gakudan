-module(gakudan_guardrail).
-moduledoc """
Guardrail behaviour. A guardrail inspects the LLM input or output at a
turn's boundary and may allow, block, or transform it.

Configured per run as an ordered list:

```erlang
guardrails => [my_pii_redactor, {my_content_policy, #{max_severity => high}}]
```

The chain runs in order: the first `{block, _}` stops it and wins; a
`{transform, _}` result feeds the next guardrail. gakudan ships no
built-in guardrails - the policy is yours; this module is only the seam.
See [ADR 0010](docs/adr/0010-guardrails.md).
""".

-export([run/4, resolve/1]).

-export_type([ref/0, stage/0, context/0, result/0]).

-type ref() :: module() | {module(), Opts :: map()}.
-type stage() :: input | output.
-type context() :: #{
    run_id := gakudan:run_id(),
    agent_id := gakudan_agent:id(),
    turn := non_neg_integer(),
    stage := stage(),
    opts := map()
}.
-type result() :: allow | {block, Reason :: term()} | {transform, NewPayload :: term()}.

-doc """
Inspect `Payload` at `Stage`. `allow` passes it through, `{block, R}`
rejects it, `{transform, P}` rewrites it for the rest of the chain.
""".
-callback check(stage(), Payload :: term(), context()) -> result().

-doc """
Run a guardrail chain over `Payload`. Returns `{ok, FinalPayload}` (after
any transforms) or `{block, {Module, Reason}}` at the first block.
`Base` supplies the non-stage context fields (`run_id`, `agent_id`, `turn`).
""".
-spec run([ref()], stage(), term(), map()) -> {ok, term()} | {block, {module(), term()}}.
run([], _Stage, Payload, _Base) ->
    {ok, Payload};
run([Ref | Rest], Stage, Payload, Base) ->
    {Mod, Opts} = resolve(Ref),
    Context = Base#{stage => Stage, opts => Opts},
    case Mod:check(Stage, Payload, Context) of
        allow -> run(Rest, Stage, Payload, Base);
        {transform, NewPayload} -> run(Rest, Stage, NewPayload, Base);
        {block, Reason} -> {block, {Mod, Reason}}
    end.

-doc "Normalise a guardrail ref into `{Module, Opts}`.".
-spec resolve(ref()) -> {module(), map()}.
resolve(Mod) when is_atom(Mod) -> {Mod, #{}};
resolve({Mod, Opts}) when is_atom(Mod), is_map(Opts) -> {Mod, Opts}.
