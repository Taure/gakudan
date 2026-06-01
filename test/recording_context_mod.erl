-module(recording_context_mod).
-moduledoc false.
-behaviour(gakudan_context).
-export([compact/3]).

%% Notifies Opts.notify with the entry count it saw, then trims to the
%% newest `keep` entries, so a test can prove the hook ran and shaped input.
compact(Entries, _Ctx, #{notify := Pid} = Opts) ->
    Pid ! {context_compacted, length(Entries)},
    Keep = maps:get(keep, Opts, length(Entries)),
    lists:nthtail(max(0, length(Entries) - Keep), Entries).
