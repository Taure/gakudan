-module(m20260525160113_update_schema).
-moduledoc false.
-behaviour(kura_migration).
-include_lib("kura/include/kura.hrl").
-export([up/0, down/0]).

-spec up() -> [kura_migration:operation()].
up() ->
    [{create_table, <<"gakudan_runs">>, [
        #kura_column{name = run_id, type = string, primary_key = true, nullable = false},
        #kura_column{name = status, type = string, nullable = false},
        #kura_column{name = last_step, type = integer, nullable = false, default = 0},
        #kura_column{name = data, type = binary, nullable = false},
        #kura_column{name = updated_at, type = utc_datetime, nullable = false},
        #kura_column{name = inserted_at, type = utc_datetime}
    ]},
     {create_table, <<"gakudan_steps">>, [
        #kura_column{name = step_id, type = string, primary_key = true, nullable = false},
        #kura_column{name = run_id, type = string, nullable = false},
        #kura_column{name = agent_id, type = string, nullable = false},
        #kura_column{name = turn, type = integer, nullable = false},
        #kura_column{name = tokens_in, type = integer, nullable = false, default = 0},
        #kura_column{name = tokens_out, type = integer, nullable = false, default = 0},
        #kura_column{name = data, type = binary, nullable = false},
        #kura_column{name = inserted_at, type = utc_datetime, nullable = false}
    ]}].

-spec down() -> [kura_migration:operation()].
down() ->
    [{drop_table, <<"gakudan_runs">>},
     {drop_table, <<"gakudan_steps">>}].
