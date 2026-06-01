-module(gakudan_router_auto).
-moduledoc """
Auto (LLM-select) router: the agent that just spoke names the next speaker.

Unlike `gakudan_router_manager` (where a single designated manager always
picks) and `gakudan_router_handoff` (a fixed `@agent` baton), this lets any
agent steer the conversation. After each turn the last speaker's text is
scanned for a `next: <agent_id>` directive (case-insensitive); that agent
runs next. `done` ends the run. With neither directive the run goes idle so
a human or caller can intervene.

Opts:
- `start := AgentId` - who speaks first.
- `agents => [AgentId]` - the selectable set (defaults to all run agents).

This is the most open-ended built-in router; pair it with a system prompt
that instructs agents to end with `next: <peer>` or `done`.
""".

-behaviour(gakudan_router).

-export([init/2, next/2]).

init(#{start := Start} = Opts, Agents) ->
    Selectable = maps:get(agents, Opts, Agents),
    case lists:member(Start, Agents) of
        true ->
            {ok, #{
                current => Start,
                selectable => Selectable,
                started => false
            }};
        false ->
            error({auto_router_unknown_start, Start, Agents})
    end.

next(#{started := false, current := A} = State, _Transcript) ->
    {next, A, State#{started := true}};
next(#{current := Current, selectable := Selectable} = State, Transcript) ->
    case last_agent_text(Transcript, Current) of
        {ok, Text} ->
            case parse_directive(Text, Selectable) of
                {next, Next} -> {next, Next, State#{current := Next}};
                done -> {done, State};
                none -> {done, State}
            end;
        none ->
            {done, State}
    end.

last_agent_text(Transcript, AgentId) ->
    case
        lists:reverse([
            T
         || #{role := {agent, A}, content := T} <- Transcript, A =:= AgentId
        ])
    of
        [Latest | _] -> {ok, Latest};
        [] -> none
    end.

%% An explicit `next:` directive wins over a `done` token so that a
%% sentence like "my turn done. next: b" routes to b rather than ending.
parse_directive(Text, Selectable) when is_binary(Text) ->
    Lower = string:lowercase(Text),
    case find_next(Lower, Selectable) of
        {next, _} = Next -> Next;
        none -> done_or_none(Lower)
    end.

done_or_none(Lower) ->
    case binary:match(Lower, ~"done") of
        nomatch -> none;
        _ -> done
    end.

find_next(_Text, []) ->
    none;
find_next(Text, [A | Rest]) ->
    Token = iolist_to_binary([~"next: ", atom_to_binary(A)]),
    case binary:match(Text, Token) of
        nomatch -> find_next(Text, Rest);
        _ -> {next, A}
    end.
