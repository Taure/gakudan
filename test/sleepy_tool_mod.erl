-module(sleepy_tool_mod).
-moduledoc false.
-behaviour(gakudan_tool).
-export([spec/0, run/1, idempotent/0]).

%% Sleeps for `delay` ms then echoes `label`. Used to prove parallel tool
%% execution gathers results in block order regardless of completion order.
spec() ->
    #{
        name => ~"sleepy_tool",
        description => ~"Sleeps then echoes a label.",
        input_schema => #{
            type => ~"object",
            properties => #{
                label => #{type => ~"string"},
                delay => #{type => ~"integer"}
            },
            required => [~"label"]
        }
    }.

run(#{~"label" := Label} = Input) ->
    Delay = maps:get(~"delay", Input, 0),
    timer:sleep(Delay),
    {ok, Label}.

idempotent() -> false.
