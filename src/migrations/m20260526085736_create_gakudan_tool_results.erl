-module(m20260526085736_create_gakudan_tool_results).
-moduledoc false.
-behaviour(kura_migration).
-include_lib("kura/include/kura.hrl").
-export([up/0, down/0]).

-spec up() -> [kura_migration:operation()].
up() ->
    [{create_table, <<"gakudan_tool_results">>, [
        #kura_column{name = tool_step_id, type = string, primary_key = true, nullable = false},
        #kura_column{name = run_id, type = string, nullable = false},
        #kura_column{name = agent_id, type = string, nullable = false},
        #kura_column{name = turn, type = integer, nullable = false},
        #kura_column{name = tool_name, type = string, nullable = false},
        #kura_column{name = data, type = binary, nullable = false},
        #kura_column{name = inserted_at, type = utc_datetime, nullable = false}
    ]}].

-spec down() -> [kura_migration:operation()].
down() ->
    [{drop_table, <<"gakudan_tool_results">>}].
