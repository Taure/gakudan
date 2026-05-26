-module(m20260526214505_alter_gakudan_audit).
-moduledoc false.
-behaviour(kura_migration).
-include_lib("kura/include/kura.hrl").
-export([up/0, down/0]).

-spec up() -> [kura_migration:operation()].
up() ->
    [{alter_table, <<"gakudan_audit">>, [
        {add_column, #kura_column{name = prev_hash, type = string}},
        {add_column, #kura_column{name = row_hash, type = string}}
    ]}].

-spec down() -> [kura_migration:operation()].
down() ->
    [{alter_table, <<"gakudan_audit">>, [
        {drop_column, prev_hash},
        {drop_column, row_hash}
    ]}].
