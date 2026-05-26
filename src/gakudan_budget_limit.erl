-module(gakudan_budget_limit).
-moduledoc """
Built-in `gakudan_budget` with declarative caps. The universal, non-opinionated
ceilings - tokens and call counts, no pricing.

Opts (all optional; the first cap met or exceeded denies):

- `max_tokens` - total input + output tokens.
- `max_input_tokens` - input tokens only.
- `max_output_tokens` - output tokens only.
- `max_llm_calls` - LLM requests across the run.
- `max_turns` - turns dispatched (orthogonal to `run_config`'s `max_turns`).

A deny carries `{deny, {Cap, Limit}}`, e.g. `{deny, {max_tokens, 100000}}`.
See [ADR 0013](docs/adr/0013-cost-budgets.md).
""".

-behaviour(gakudan_budget).

-export([check/2]).

-spec check(gakudan_budget:usage(), gakudan_budget:context()) -> gakudan_budget:result().
check(Usage, #{opts := Opts}) ->
    eval(
        [
            {max_tokens, total_tokens},
            {max_input_tokens, tokens_in},
            {max_output_tokens, tokens_out},
            {max_llm_calls, llm_calls},
            {max_turns, turns}
        ],
        Usage,
        Opts
    ).

eval([], _Usage, _Opts) ->
    allow;
eval([{Cap, UsageKey} | Rest], Usage, Opts) ->
    case maps:get(Cap, Opts, undefined) of
        undefined ->
            eval(Rest, Usage, Opts);
        Limit ->
            case maps:get(UsageKey, Usage, 0) >= Limit of
                true -> {deny, {Cap, Limit}};
                false -> eval(Rest, Usage, Opts)
            end
    end.
