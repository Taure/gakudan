-module(gakudan_audit_ets).
-moduledoc false.

-behaviour(gakudan_audit).

-export([init/1, record/2]).
-export([new/0, reset/1, events/2, all/1]).

new() ->
    Tab = ensure_table(gakudan_audit_events),
    #{tab => Tab}.

ensure_table(Name) ->
    case ets:whereis(Name) of
        undefined ->
            ets:new(Name, [named_table, public, ordered_set, {heir, whereis(init), undefined}]);
        _Tid ->
            ok
    end,
    Name.

reset(#{tab := Tab}) ->
    ets:delete_all_objects(Tab),
    ok.

init(#{tab := _} = State) ->
    {ok, State};
init(_) ->
    {error, {bad_config, missing_tab}}.

record(State, Event) ->
    Type = maps:get(type, Event),
    case maps:get(fail, State, false) orelse lists:member(Type, maps:get(fail_types, State, [])) of
        true ->
            {error, induced_failure};
        false ->
            #{tab := Tab} = State,
            Key = erlang:unique_integer([monotonic]),
            true = ets:insert(Tab, {Key, maps:get(run_id, Event), Event}),
            ok
    end.

events(#{tab := Tab}, RunId) ->
    [E || {_K, R, E} <- ets:tab2list(Tab), R =:= RunId].

all(#{tab := Tab}) ->
    [E || {_K, _R, E} <- ets:tab2list(Tab)].
