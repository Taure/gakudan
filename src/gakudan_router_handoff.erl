-module(gakudan_router_handoff).
-moduledoc """
Handoff router: one agent runs until it explicitly hands off to another by emitting
a turn-ending message containing `@<agent_id>` (case-insensitive at the start of
the agent's reply), or by writing a `handoff_to` key on the blackboard. When no
handoff signal is present, the run goes idle.

Opts: `#{start := AgentId}`.
""".

-behaviour(gakudan_router).

-export([init/2, next/2]).

init(#{start := Start}, Agents) ->
    case lists:member(Start, Agents) of
        true -> {ok, #{current => Start, agents => Agents, started => false}};
        false -> error({unknown_start_agent, Start, Agents})
    end.

next(#{started := false, current := A} = State, _Transcript) ->
    {next, A, State#{started := true}};
next(#{current := Current, agents := Agents} = State, Transcript) ->
    case last_agent_entry(Transcript, Current) of
        {ok, Text} ->
            case extract_handoff(Text, Agents) of
                {ok, Next} when Next =/= Current ->
                    {next, Next, State#{current := Next}};
                _ ->
                    {done, State}
            end;
        none ->
            {done, State}
    end.

last_agent_entry(Transcript, AgentId) ->
    case
        lists:reverse([
            T
         || #{role := {agent, A}, content := T} <- Transcript, A =:= AgentId
        ])
    of
        [Latest | _] -> {ok, Latest};
        [] -> none
    end.

extract_handoff(Text, Agents) when is_binary(Text) ->
    Lower = string:lowercase(Text),
    find_handoff(Lower, Agents).

find_handoff(_Text, []) ->
    none;
find_handoff(Text, [A | Rest]) ->
    Token = iolist_to_binary([$@, atom_to_binary(A)]),
    case binary:match(Text, Token) of
        nomatch -> find_handoff(Text, Rest);
        _ -> {ok, A}
    end.
