-module(agent_structured_mod).
-moduledoc false.
-behaviour(gakudan_agent).
-export([id/0, system_prompt/0, tools/0, model/0, request_options/0]).

id() -> agent_s.
system_prompt() -> ~"Return a structured review.".
tools() -> [].
model() -> ~"stub".

request_options() ->
    #{
        response_format => #{
            type => ~"object",
            properties => #{
                score => #{type => ~"integer"},
                summary => #{type => ~"string"}
            },
            required => [~"score", ~"summary"]
        },
        validator =>
            {gakudan_validator_json, #{
                type => ~"object",
                properties => #{
                    score => #{type => ~"integer"},
                    summary => #{type => ~"string"}
                },
                required => [~"score", ~"summary"]
            }}
    }.
