-module(gakudan_turn).
-moduledoc false.

-export([run/8]).

-define(MAX_TOOL_ITERATIONS, 10).

-spec run(
    gakudan:run_id(),
    gakudan_agent:id(),
    module(),
    pos_integer(),
    undefined | {module(), term()},
    module(),
    map(),
    pid()
) -> ok.
run(RunId, AgentId, AgentMod, Turn, Checkpointer, LlmMod, LlmOpts, Blackboard) ->
    System = AgentMod:system_prompt(),
    Tools = [T:spec() || T <- AgentMod:tools()],
    Model = AgentMod:model(),
    Transcript = gakudan_blackboard:entries(Blackboard),
    Messages = transcript_to_messages(Transcript, AgentId),
    Ctx = #{
        run_id => RunId,
        agent_id => AgentId,
        turn => Turn,
        checkpointer => Checkpointer
    },
    loop(Ctx, AgentMod, System, Tools, Model, LlmMod, LlmOpts, Blackboard, Messages, 0).

loop(_Ctx, _AgentMod, _Sys, _Tools, _Model, _LMod, _LOpts, _BB, _Msgs, N) when
    N >= ?MAX_TOOL_ITERATIONS
->
    ok;
loop(
    #{run_id := RunId, agent_id := AgentId} = Ctx,
    AgentMod,
    Sys,
    Tools,
    Model,
    LMod,
    LOpts,
    BB,
    Msgs,
    N
) ->
    Req = #{model => Model, system => Sys, tools => Tools, messages => Msgs},
    case complete_with_idempotency(Ctx, N, LMod, Model, Req, LOpts) of
        {ok, #{stop_reason := end_turn, content := Content}} ->
            Text = collect_text(Content),
            {ok, _} = gakudan_blackboard:append(BB, {agent, AgentId}, Text),
            ok;
        {ok, #{stop_reason := tool_use, content := Content}} ->
            ToolUses = [B || #{type := tool_use} = B <- Content],
            ToolResults = run_tools(RunId, AgentId, AgentMod:tools(), ToolUses),
            AssistantTurn = #{role => assistant, content => Content},
            UserTurn = #{role => user, content => ToolResults},
            loop(
                Ctx,
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

complete_with_idempotency(Ctx, Iter, LMod, Model, Req, LOpts) ->
    #{run_id := RunId, agent_id := AgentId, turn := Turn, checkpointer := Checkpointer} = Ctx,
    StepId = step_id(RunId, Turn, AgentId, Iter),
    case Checkpointer of
        undefined ->
            complete_with_telemetry(RunId, AgentId, LMod, Model, Req, LOpts);
        _ ->
            case gakudan_checkpointer:load_step(Checkpointer, RunId, StepId) of
                {ok, #{response := CachedResp}} ->
                    {ok, CachedResp};
                {error, not_found} ->
                    case complete_with_telemetry(RunId, AgentId, LMod, Model, Req, LOpts) of
                        {ok, Resp} = Ok ->
                            persist_step(Checkpointer, RunId, StepId, AgentId, Turn, Req, Resp),
                            Ok;
                        {error, _} = Err ->
                            Err
                    end
            end
    end.

persist_step(Checkpointer, RunId, StepId, AgentId, Turn, Req, Resp) ->
    Usage = maps:get(usage, Resp, #{input_tokens => 0, output_tokens => 0}),
    Step = #{
        run_id => RunId,
        step_id => StepId,
        agent_id => AgentId,
        turn => Turn,
        request => Req,
        response => Resp,
        usage => Usage,
        inserted_at => erlang:system_time(millisecond)
    },
    _ = gakudan_checkpointer:save_step(Checkpointer, Step),
    ok.

step_id(RunId, Turn, AgentId, Iter) ->
    Input = iolist_to_binary([
        RunId,
        $|,
        integer_to_binary(Turn),
        $|,
        atom_to_binary(AgentId),
        $|,
        integer_to_binary(Iter)
    ]),
    Hash = crypto:hash(sha256, Input),
    binary:encode_hex(Hash, lowercase).

complete_with_telemetry(RunId, AgentId, LMod, Model, Req, LOpts) ->
    StartMeta = #{run_id => RunId, agent_id => AgentId, backend => LMod, model => Model},
    telemetry:span(
        [gakudan, llm, request],
        StartMeta,
        fun() ->
            case LMod:complete(Req, LOpts) of
                {ok, Resp} = Ok ->
                    Usage = maps:get(usage, Resp, #{input_tokens => 0, output_tokens => 0}),
                    Measurements = #{
                        tokens_in => maps:get(input_tokens, Usage, 0),
                        tokens_out => maps:get(output_tokens, Usage, 0)
                    },
                    {Ok, Measurements, StartMeta#{outcome => ok}};
                {error, Reason} = Err ->
                    Measurements = #{tokens_in => 0, tokens_out => 0},
                    {Err, Measurements, StartMeta#{outcome => error, reason => Reason}}
            end
        end
    ).

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

run_tools(RunId, AgentId, ToolMods, ToolUses) ->
    NameMap = maps:from_list([{maps:get(name, M:spec()), M} || M <- ToolMods]),
    lists:map(
        fun(#{id := Id, name := Name, input := Input}) ->
            case maps:find(Name, NameMap) of
                {ok, Mod} ->
                    case run_tool_with_telemetry(RunId, AgentId, Name, Mod, Input) of
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

run_tool_with_telemetry(RunId, AgentId, Name, Mod, Input) ->
    StartMeta = #{run_id => RunId, agent_id => AgentId, tool => Name},
    telemetry:span(
        [gakudan, tool, run],
        StartMeta,
        fun() ->
            case safe_run_tool(Mod, Input) of
                {ok, _} = Ok -> {Ok, StartMeta#{outcome => ok}};
                {error, Reason} = Err -> {Err, StartMeta#{outcome => error, reason => Reason}}
            end
        end
    ).

safe_run_tool(Mod, Input) ->
    try
        Mod:run(Input)
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.
