-module(gakudan_checkpointer_ets).
-moduledoc false.

-behaviour(gakudan_checkpointer).

-export([
    init/1,
    save_snapshot/2,
    load_snapshot/2,
    list_active/1,
    delete_run/2,
    save_step/2,
    load_step/3
]).

-export([new/0, reset/1]).

new() ->
    Snaps = ensure_table(gakudan_ckp_snaps),
    Steps = ensure_table(gakudan_ckp_steps),
    #{snaps => Snaps, steps => Steps}.

ensure_table(Name) ->
    case ets:whereis(Name) of
        undefined ->
            ets:new(Name, [named_table, public, set, {heir, whereis(init), undefined}]);
        Tid ->
            Tid
    end,
    Name.

reset(#{snaps := S, steps := T}) ->
    ets:delete_all_objects(S),
    ets:delete_all_objects(T),
    ok.

init(Opts) ->
    {ok, Opts}.

save_snapshot(#{snaps := Tab}, #{run_id := RunId} = Snapshot) ->
    true = ets:insert(Tab, {RunId, Snapshot}),
    ok.

load_snapshot(#{snaps := Tab}, RunId) ->
    case ets:lookup(Tab, RunId) of
        [{_, Snapshot}] -> {ok, Snapshot};
        [] -> {error, not_found}
    end.

list_active(#{snaps := Tab}) ->
    Active = ets:foldl(
        fun({RunId, #{status := S}}, Acc) ->
            case S of
                running -> [RunId | Acc];
                idle -> [RunId | Acc];
                awaiting_human -> [RunId | Acc];
                _ -> Acc
            end
        end,
        [],
        Tab
    ),
    {ok, Active}.

delete_run(#{snaps := Snaps, steps := Steps}, RunId) ->
    true = ets:delete(Snaps, RunId),
    ets:match_delete(Steps, {{RunId, '_'}, '_'}),
    ok.

save_step(#{steps := Tab}, #{run_id := RunId, step_id := StepId} = Step) ->
    true = ets:insert(Tab, {{RunId, StepId}, Step}),
    ok.

load_step(#{steps := Tab}, RunId, StepId) ->
    case ets:lookup(Tab, {RunId, StepId}) of
        [{_, Step}] -> {ok, Step};
        [] -> {error, not_found}
    end.
