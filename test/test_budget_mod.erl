-module(test_budget_mod).
-moduledoc false.

-behaviour(gakudan_budget).

-export([check/2]).

check(#{turns := Turns}, #{opts := #{deny_after := N}}) when Turns >= N ->
    {deny, {turns_over, N}};
check(_Usage, _Ctx) ->
    allow.
