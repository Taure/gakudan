-module(gakudan_validator_json).
-moduledoc """
Default JSON-schema validator for structured LLM output.

Validates a parsed value (the term produced by `json:decode/1`) against a
practical JSON-schema subset: `type`, `required`, `properties`, `items`,
and `enum`. Nested objects and arrays are validated recursively. Schema
keys may be atoms or binaries; the `type` value may be an atom or binary.

This is the reference `gakudan_validator` implementation. It does not aim
for full JSON-schema coverage - just the constructs that constrain LLM
output in practice. See [ADR 0017](docs/adr/0017-structured-output-validation.md).
""".

-behaviour(gakudan_validator).

-export([validate/2]).

-doc "Validate `Value` against the JSON `Schema`. See `m:gakudan_validator`.".
-spec validate(map(), term()) -> gakudan_validator:result().
validate(Schema, Value) ->
    case check(Schema, Value, ~"$") of
        [] -> {ok, Value};
        Errors -> {error, Errors}
    end.

check(Schema, Value, Path) ->
    type_errors(Schema, Value, Path) ++
        enum_errors(Schema, Value, Path) ++
        object_errors(Schema, Value, Path) ++
        array_errors(Schema, Value, Path).

type_errors(Schema, Value, Path) ->
    case schema_get(type, Schema) of
        undefined ->
            [];
        Type ->
            case matches_type(normalise_type(Type), Value) of
                true -> [];
                false -> [{Path, {expected_type, normalise_type(Type)}}]
            end
    end.

enum_errors(Schema, Value, Path) ->
    case schema_get(enum, Schema) of
        undefined ->
            [];
        Allowed when is_list(Allowed) ->
            case lists:member(Value, Allowed) of
                true -> [];
                false -> [{Path, {not_in_enum, Allowed}}]
            end
    end.

object_errors(Schema, Value, Path) when is_map(Value) ->
    required_errors(Schema, Value, Path) ++ property_errors(Schema, Value, Path);
object_errors(_Schema, _Value, _Path) ->
    [].

required_errors(Schema, Value, Path) ->
    case schema_get(required, Schema) of
        undefined ->
            [];
        Keys when is_list(Keys) ->
            [
                {join(Path, K), missing}
             || K <- Keys, not has_key(K, Value)
            ]
    end.

property_errors(Schema, Value, Path) ->
    case schema_get(properties, Schema) of
        undefined ->
            [];
        Props when is_map(Props) ->
            lists:append([
                check(SubSchema, SubValue, join(Path, Key))
             || {Key, SubSchema} <- maps:to_list(Props),
                {present, SubValue} <- [fetch_opt(Key, Value)]
            ])
    end.

array_errors(Schema, Value, Path) when is_list(Value) ->
    case schema_get(items, Schema) of
        undefined ->
            [];
        ItemSchema when is_map(ItemSchema) ->
            lists:append([
                check(ItemSchema, Item, join(Path, integer_to_binary(Idx)))
             || {Idx, Item} <- lists:enumerate(0, Value)
            ])
    end;
array_errors(_Schema, _Value, _Path) ->
    [].

matches_type(object, V) -> is_map(V);
matches_type(array, V) -> is_list(V);
matches_type(string, V) -> is_binary(V);
matches_type(integer, V) -> is_integer(V);
matches_type(number, V) -> is_number(V);
matches_type(boolean, V) -> is_boolean(V);
matches_type(null, V) -> V =:= null;
matches_type(_Other, _V) -> true.

normalise_type(T) when is_atom(T) -> T;
normalise_type(~"object") -> object;
normalise_type(~"array") -> array;
normalise_type(~"string") -> string;
normalise_type(~"integer") -> integer;
normalise_type(~"number") -> number;
normalise_type(~"boolean") -> boolean;
normalise_type(~"null") -> null;
normalise_type(Other) when is_binary(Other) -> Other.

schema_get(Key, Schema) ->
    case fetch_opt(Key, Schema) of
        {present, V} -> V;
        absent -> undefined
    end.

has_key(Key, Value) ->
    fetch_opt(Key, Value) =/= absent.

%% Look up a key that may be present as an atom or its binary form.
fetch_opt(Key, Map) when is_binary(Key) ->
    case Map of
        #{Key := V} -> {present, V};
        _ -> absent
    end;
fetch_opt(Key, Map) when is_atom(Key) ->
    case Map of
        #{Key := V} -> {present, V};
        #{} -> fetch_opt(atom_to_binary(Key), Map)
    end.

join(Path, Key) when is_atom(Key) ->
    join(Path, atom_to_binary(Key));
join(Path, Key) when is_binary(Key) ->
    <<Path/binary, ".", Key/binary>>.
