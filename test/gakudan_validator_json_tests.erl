-module(gakudan_validator_json_tests).
-include_lib("eunit/include/eunit.hrl").

valid_object_test() ->
    Schema = #{
        type => ~"object",
        properties => #{
            name => #{type => ~"string"},
            age => #{type => ~"integer"}
        },
        required => [~"name", ~"age"]
    },
    Value = #{~"name" => ~"Ada", ~"age" => 36},
    ?assertEqual({ok, Value}, gakudan_validator_json:validate(Schema, Value)).

missing_required_test() ->
    Schema = #{type => ~"object", required => [~"name", ~"age"]},
    Value = #{~"name" => ~"Ada"},
    {error, Errors} = gakudan_validator_json:validate(Schema, Value),
    ?assertEqual(1, length(Errors)),
    [{Path, missing}] = Errors,
    ?assertEqual(~"$.age", Path).

wrong_type_test() ->
    Schema = #{type => ~"object", properties => #{age => #{type => ~"integer"}}},
    Value = #{~"age" => ~"thirty"},
    {error, [{Path, {expected_type, integer}}]} = gakudan_validator_json:validate(Schema, Value),
    ?assertEqual(~"$.age", Path).

enum_test() ->
    Schema = #{enum => [~"red", ~"green", ~"blue"]},
    ?assertEqual({ok, ~"green"}, gakudan_validator_json:validate(Schema, ~"green")),
    ?assertMatch(
        {error, [{~"$", {not_in_enum, _}}]},
        gakudan_validator_json:validate(Schema, ~"mauve")
    ).

nested_object_test() ->
    Schema = #{
        type => ~"object",
        properties => #{
            user => #{
                type => ~"object",
                properties => #{id => #{type => ~"integer"}},
                required => [~"id"]
            }
        }
    },
    Bad = #{~"user" => #{~"id" => ~"x"}},
    {error, [{Path, {expected_type, integer}}]} = gakudan_validator_json:validate(Schema, Bad),
    ?assertEqual(~"$.user.id", Path).

array_items_test() ->
    Schema = #{type => ~"array", items => #{type => ~"integer"}},
    ?assertEqual({ok, [1, 2, 3]}, gakudan_validator_json:validate(Schema, [1, 2, 3])),
    {error, [{Path, {expected_type, integer}}]} =
        gakudan_validator_json:validate(Schema, [1, ~"two", 3]),
    ?assertEqual(~"$.1", Path).

atom_schema_keys_test() ->
    Schema = #{type => object, properties => #{n => #{type => integer}}, required => [n]},
    ?assertEqual({ok, #{~"n" => 1}}, gakudan_validator_json:validate(Schema, #{~"n" => 1})),
    ?assertMatch({error, _}, gakudan_validator_json:validate(Schema, #{})).

ref_dispatch_test() ->
    Schema = #{type => ~"object", required => [~"k"]},
    Ref = {gakudan_validator_json, Schema},
    ?assertEqual({ok, #{~"k" => 1}}, gakudan_validator:validate(Ref, #{~"k" => 1})).
