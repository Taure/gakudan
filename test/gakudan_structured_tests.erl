-module(gakudan_structured_tests).
-include_lib("eunit/include/eunit.hrl").

extract_from_tool_use_test() ->
    Name = gakudan_llm_anthropic:structured_output_tool_name(),
    Content = [
        #{type => tool_use, id => ~"t1", name => Name, input => #{~"score" => 9}}
    ],
    ?assertEqual({ok, #{~"score" => 9}}, gakudan_structured:extract(Content)).

extract_from_json_text_test() ->
    Content = [#{type => text, text => ~"{\"score\":9}"}],
    ?assertEqual({ok, #{~"score" => 9}}, gakudan_structured:extract(Content)).

extract_missing_test() ->
    Content = [#{type => text, text => ~"not json at all"}],
    ?assertEqual({error, no_structured_output}, gakudan_structured:extract(Content)).

extract_empty_test() ->
    ?assertEqual({error, no_structured_output}, gakudan_structured:extract([])).

validate_undefined_passthrough_test() ->
    ?assertEqual({ok, #{~"a" => 1}}, gakudan_structured:validate(undefined, #{~"a" => 1})).

validate_with_ref_test() ->
    Schema = #{type => ~"object", required => [~"score"]},
    Ref = {gakudan_validator_json, Schema},
    ?assertEqual({ok, #{~"score" => 9}}, gakudan_structured:validate(Ref, #{~"score" => 9})),
    ?assertMatch({error, _}, gakudan_structured:validate(Ref, #{})).
