-module(m20260605095457_alter_gakudan_runs).
-moduledoc false.
-behaviour(kura_migration).
-include_lib("kura/include/kura.hrl").
-export([up/0, down/0]).

-spec up() -> [kura_migration:operation()].
up() ->
    [{alter_table, ~"gakudan_runs", [
        {add_column, #kura_column{name = lease_expires_at, type = utc_datetime}},
        {add_column, #kura_column{name = owner_id, type = string}}
    ]},
     {create_index, ~"gakudan_runs", [status,lease_expires_at], #{}}].

-spec down() -> [kura_migration:operation()].
down() ->
    [{alter_table, ~"gakudan_runs", [
        {drop_column, lease_expires_at},
        {drop_column, owner_id}
    ]},
     {drop_index, ~"gakudan_runs_status_lease_expires_at_index"}].
