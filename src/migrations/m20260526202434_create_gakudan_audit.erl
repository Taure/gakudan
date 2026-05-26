-module(m20260526202434_create_gakudan_audit).
-moduledoc false.
-behaviour(kura_migration).
-include_lib("kura/include/kura.hrl").
-export([up/0, down/0]).

-spec up() -> [kura_migration:operation()].
up() ->
    [{create_table, <<"gakudan_audit">>, [
        #kura_column{name = id, type = string, primary_key = true, nullable = false},
        #kura_column{name = run_id, type = string, nullable = false},
        #kura_column{name = type, type = string, nullable = false},
        #kura_column{name = actor_id, type = string},
        #kura_column{name = tenant, type = string},
        #kura_column{name = agent_id, type = string},
        #kura_column{name = turn, type = integer},
        #kura_column{name = data, type = binary, nullable = false},
        #kura_column{name = event_hash, type = string, nullable = false},
        #kura_column{name = inserted_at, type = utc_datetime, nullable = false}
    ]}].

-spec down() -> [kura_migration:operation()].
down() ->
    [{drop_table, <<"gakudan_audit">>}].
