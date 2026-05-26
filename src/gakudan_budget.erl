-module(gakudan_budget).
-moduledoc """
Budget behaviour. A budget inspects a run's cumulative usage before each
turn is dispatched and may allow it to continue or deny, which stops the
run before it spends past a ceiling.

Configured per run (or via the `default_budget` app env) as a single ref:

```erlang
budget => {gakudan_budget_limit, #{max_tokens => 100000, max_llm_calls => 50}}
```

A ref is `module() | {module(), Opts :: map()}` (opts arrive in
`context.opts`). gakudan ships `gakudan_budget_limit` for the universal
token / call caps; money and per-tenant policy are yours - implement
`check/2` against your own price table or counters. See
[ADR 0013](docs/adr/0013-cost-budgets.md).
""".

-export([check/3, resolve/1]).

-export_type([ref/0, usage/0, context/0, result/0]).

-type ref() :: module() | {module(), Opts :: map()}.
-type usage() :: #{
    tokens_in := non_neg_integer(),
    tokens_out := non_neg_integer(),
    total_tokens := non_neg_integer(),
    llm_calls := non_neg_integer(),
    turns := non_neg_integer()
}.
-type context() :: #{
    run_id := gakudan:run_id(),
    actor := map(),
    opts := map()
}.
-type result() :: allow | {deny, Reason :: term()}.

-doc """
Decide whether a run carrying `Usage` may dispatch another turn. `allow`
proceeds; `{deny, Reason}` stops the run.
""".
-callback check(usage(), context()) -> result().

-doc """
Run the configured budget over `Usage`. `undefined` (no budget) always
allows. `Base` supplies `run_id` and `actor`; `opts` is filled from the ref.
A deny is tagged with the deciding module: `{deny, {Module, Reason}}`.
""".
-spec check(undefined | ref(), usage(), map()) -> allow | {deny, {module(), term()}}.
check(undefined, _Usage, _Base) ->
    allow;
check(Ref, Usage, Base) ->
    {Mod, Opts} = resolve(Ref),
    case Mod:check(Usage, Base#{opts => Opts}) of
        allow -> allow;
        {deny, Reason} -> {deny, {Mod, Reason}}
    end.

-doc "Normalise a budget ref into `{Module, Opts}`.".
-spec resolve(ref()) -> {module(), map()}.
resolve(Mod) when is_atom(Mod) -> {Mod, #{}};
resolve({Mod, Opts}) when is_atom(Mod), is_map(Opts) -> {Mod, Opts}.
