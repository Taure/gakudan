-module(gakudan_audit_schema).
-moduledoc false.

-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0]).

table() -> ~"gakudan_audit".

fields() ->
    [
        #kura_field{name = id, type = string, primary_key = true, nullable = false},
        #kura_field{name = run_id, type = string, nullable = false},
        #kura_field{name = type, type = string, nullable = false},
        #kura_field{name = actor_id, type = string, nullable = true},
        #kura_field{name = tenant, type = string, nullable = true},
        #kura_field{name = agent_id, type = string, nullable = true},
        #kura_field{name = turn, type = integer, nullable = true},
        #kura_field{name = data, type = binary, nullable = false},
        #kura_field{name = event_hash, type = string, nullable = false},
        %% Nullable so the alter is safe to add to an existing table; the sink
        %% always populates them, so new rows are never null.
        #kura_field{name = prev_hash, type = string, nullable = true},
        #kura_field{name = row_hash, type = string, nullable = true},
        #kura_field{name = inserted_at, type = utc_datetime, nullable = false}
    ].
