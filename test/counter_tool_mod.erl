-module(counter_tool_mod).
-moduledoc false.

-behaviour(gakudan_tool).

-export([spec/0, run/1, reset/0, count/0]).

-define(TAB, counter_tool_mod_count).

spec() ->
    #{
        name => ~"counter_tool",
        description => ~"increments a call counter",
        input_schema => #{type => object, properties => #{}}
    }.

run(_Input) ->
    _ = ets:update_counter(?TAB, count, 1),
    {ok, ~"ok"}.

reset() ->
    case ets:whereis(?TAB) of
        undefined -> ets:new(?TAB, [named_table, public]);
        _ -> ok
    end,
    true = ets:insert(?TAB, {count, 0}),
    ok.

count() ->
    ets:lookup_element(?TAB, count, 2).
