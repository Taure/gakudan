-module(gakudan_turn).
-moduledoc false.

-export([run/6]).

-define(MAX_TOOL_ITERATIONS, 10).

-spec run(
    gakudan_agent:id(),
    module(),
    map(),
    module(),
    map(),
    pid()
) -> ok.
run(AgentId, AgentMod, _AgentOpts, LlmMod, LlmOpts, Blackboard) ->
    System = AgentMod:system_prompt(),
    Tools = [T:spec() || T <- AgentMod:tools()],
    Model = AgentMod:model(),
    Transcript = gakudan_blackboard:entries(Blackboard),
    Messages = transcript_to_messages(Transcript, AgentId),
    loop(AgentId, AgentMod, System, Tools, Model, LlmMod, LlmOpts, Blackboard, Messages, 0).

loop(_AgentId, _AgentMod, _Sys, _Tools, _Model, _LMod, _LOpts, _BB, _Msgs, N) when
    N >= ?MAX_TOOL_ITERATIONS
->
    ok;
loop(AgentId, AgentMod, Sys, Tools, Model, LMod, LOpts, BB, Msgs, N) ->
    Req = #{model => Model, system => Sys, tools => Tools, messages => Msgs},
    case LMod:complete(Req, LOpts) of
        {ok, #{stop_reason := end_turn, content := Content}} ->
            Text = collect_text(Content),
            {ok, _} = gakudan_blackboard:append(BB, {agent, AgentId}, Text),
            ok;
        {ok, #{stop_reason := tool_use, content := Content}} ->
            ToolUses = [B || #{type := tool_use} = B <- Content],
            ToolResults = run_tools(AgentMod:tools(), ToolUses),
            AssistantTurn = #{role => assistant, content => Content},
            UserTurn = #{role => user, content => ToolResults},
            loop(
                AgentId,
                AgentMod,
                Sys,
                Tools,
                Model,
                LMod,
                LOpts,
                BB,
                Msgs ++ [AssistantTurn, UserTurn],
                N + 1
            );
        {error, Reason} ->
            error({llm_error, Reason})
    end.

transcript_to_messages(Entries, Self) ->
    %% Map blackboard log into Anthropic-style role/content messages.
    %% Self's prior turns -> assistant; others (user + other agents + system) -> user
    %% (with a small prefix identifying speaker).
    lists:map(
        fun(#{role := Role, content := Content}) ->
            case Role of
                {agent, Self} ->
                    #{role => assistant, content => to_text(Content)};
                {agent, Other} ->
                    #{
                        role => user,
                        content => iolist_to_binary([
                            "[", atom_to_binary(Other), "]: ", to_text(Content)
                        ])
                    };
                user ->
                    #{role => user, content => to_text(Content)};
                system ->
                    #{
                        role => user,
                        content => iolist_to_binary([~"[system]: ", to_text(Content)])
                    }
            end
        end,
        Entries
    ).

to_text(B) when is_binary(B) -> B;
to_text(L) when is_list(L) -> iolist_to_binary(io_lib:format("~p", [L])).

collect_text(Content) ->
    Texts = [T || #{type := text, text := T} <- Content],
    iolist_to_binary(lists:join(~"\n", Texts)).

run_tools(ToolMods, ToolUses) ->
    NameMap = maps:from_list([{maps:get(name, M:spec()), M} || M <- ToolMods]),
    lists:map(
        fun(#{id := Id, name := Name, input := Input}) ->
            case maps:find(Name, NameMap) of
                {ok, Mod} ->
                    case safe_run_tool(Mod, Input) of
                        {ok, Output} ->
                            #{
                                type => tool_result,
                                tool_use_id => Id,
                                content => to_text(Output)
                            };
                        {error, Reason} ->
                            #{
                                type => tool_result,
                                tool_use_id => Id,
                                is_error => true,
                                content => iolist_to_binary(io_lib:format("error: ~p", [Reason]))
                            }
                    end;
                error ->
                    #{
                        type => tool_result,
                        tool_use_id => Id,
                        is_error => true,
                        content => <<"unknown tool: ", Name/binary>>
                    }
            end
        end,
        ToolUses
    ).

safe_run_tool(Mod, Input) ->
    try
        Mod:run(Input)
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.
