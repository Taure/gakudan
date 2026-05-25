-module(gakudan_step_schema).
-moduledoc false.

-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0]).

table() -> ~"gakudan_steps".

fields() ->
    [
        #kura_field{name = step_id, type = string, primary_key = true, nullable = false},
        #kura_field{name = run_id, type = string, nullable = false},
        #kura_field{name = agent_id, type = string, nullable = false},
        #kura_field{name = turn, type = integer, nullable = false},
        #kura_field{name = tokens_in, type = integer, nullable = false, default = 0},
        #kura_field{name = tokens_out, type = integer, nullable = false, default = 0},
        #kura_field{name = data, type = binary, nullable = false},
        #kura_field{name = inserted_at, type = utc_datetime, nullable = false}
    ].
