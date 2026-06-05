-module(gakudan_run_schema).
-moduledoc false.

-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, indexes/0]).

table() -> ~"gakudan_runs".

fields() ->
    [
        #kura_field{name = run_id, type = string, primary_key = true, nullable = false},
        #kura_field{name = status, type = string, nullable = false},
        #kura_field{name = last_step, type = integer, nullable = false, default = 0},
        #kura_field{name = data, type = binary, nullable = false},
        #kura_field{name = owner_id, type = string},
        #kura_field{name = lease_expires_at, type = utc_datetime},
        #kura_field{name = updated_at, type = utc_datetime, nullable = false},
        #kura_field{name = inserted_at, type = utc_datetime}
    ].

indexes() ->
    [{[status, lease_expires_at], #{}}].
