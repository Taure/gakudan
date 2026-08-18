-module(agent_reviewer_a_mod).
-moduledoc false.
-behaviour(gakudan_agent).
-export([id/0, system_prompt/0, tools/0, model/0, request_options/0]).

id() -> reviewer_a.
system_prompt() -> ~"Reviewer a: return a structured finding.".
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
