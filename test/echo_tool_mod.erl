-module(echo_tool_mod).
-moduledoc false.
-behaviour(gakudan_tool).
-export([spec/0, run/1]).

spec() ->
    #{
        name => ~"echo_tool",
        description => ~"Echoes its input back.",
        input_schema => #{
            type => ~"object",
            properties => #{msg => #{type => ~"string"}},
            required => [~"msg"]
        }
    }.

run(#{~"msg" := Msg}) -> {ok, Msg};
run(_) -> {error, bad_input}.
