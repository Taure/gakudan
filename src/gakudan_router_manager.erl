-module(gakudan_router_manager).
-moduledoc """
Manager router: a designated manager agent picks which worker runs next.

The manager produces a turn whose text ends with `next: <agent_id>` (or `done`).
Workers run between manager turns. This is the simplest pattern that lets a
"team lead" LLM coordinate specialists.

Opts: `#{manager := AgentId, workers := [AgentId]}`.
""".

-behaviour(gakudan_router).

-export([init/2, next/2]).

init(#{manager := Mgr, workers := Workers}, Agents) ->
    All = [Mgr | Workers],
    case lists:all(fun(A) -> lists:member(A, Agents) end, All) of
        true ->
            {ok, #{
                manager => Mgr,
                workers => Workers,
                phase => manager,
                last_pick => undefined,
                turns => 0
            }};
        false ->
            error({manager_router_missing_agents, All, Agents})
    end.

next(#{phase := manager, manager := Mgr} = State, _Transcript) ->
    {next, Mgr, State#{phase := await_manager_pick, turns := maps:get(turns, State) + 1}};
next(#{phase := await_manager_pick, manager := Mgr, workers := Workers} = State, Transcript) ->
    case last_text_of(Mgr, Transcript) of
        {ok, Text} ->
            case parse_pick(Text, Workers) of
                {ok, Worker} ->
                    {next, Worker, State#{phase := manager, last_pick := Worker}};
                done ->
                    {done, State};
                none ->
                    {done, State}
            end;
        none ->
            {done, State}
    end.

last_text_of(Agent, Transcript) ->
    case
        lists:reverse([
            T
         || #{role := {agent, A}, content := T} <- Transcript, A =:= Agent
        ])
    of
        [Latest | _] -> {ok, Latest};
        [] -> none
    end.

parse_pick(Text, Workers) ->
    Lower = string:lowercase(Text),
    case binary:match(Lower, ~"done") of
        nomatch ->
            find_next(Lower, Workers);
        _ ->
            done
    end.

find_next(_Text, []) ->
    none;
find_next(Text, [W | Rest]) ->
    Token = iolist_to_binary([~"next: ", atom_to_binary(W)]),
    case binary:match(Text, Token) of
        nomatch -> find_next(Text, Rest);
        _ -> {ok, W}
    end.
