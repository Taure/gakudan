-module(gakudan_turn).
-moduledoc false.

-export([run/10, run/11]).

-define(MAX_TOOL_ITERATIONS, 10).

-type audit_ctx() :: #{audit => gakudan_audit:handle(), actor => map()}.

-spec run(
    gakudan:run_id(),
    gakudan_agent:id(),
    module(),
    pos_integer(),
    undefined | {module(), term()},
    module(),
    map(),
    pid(),
    undefined | pid(),
    [gakudan_guardrail:ref()]
) -> ok.
run(RunId, AgentId, AgentMod, Turn, Checkpointer, LlmMod, LlmOpts, Blackboard, Stream, Guardrails) ->
    run(
        RunId,
        AgentId,
        AgentMod,
        Turn,
        Checkpointer,
        LlmMod,
        LlmOpts,
        Blackboard,
        Stream,
        Guardrails,
        #{}
    ).

-spec run(
    gakudan:run_id(),
    gakudan_agent:id(),
    module(),
    pos_integer(),
    undefined | {module(), term()},
    module(),
    map(),
    pid(),
    undefined | pid(),
    [gakudan_guardrail:ref()],
    audit_ctx()
) -> ok.
run(
    RunId,
    AgentId,
    AgentMod,
    Turn,
    Checkpointer,
    LlmMod,
    LlmOpts,
    Blackboard,
    Stream,
    Guardrails,
    AuditCtx
) ->
    System = AgentMod:system_prompt(),
    ResolvedTools = gakudan_tool:resolve(AgentMod:tools()),
    Specs = [maps:get(spec, R) || R <- ResolvedTools],
    Model = AgentMod:model(),
    Transcript = gakudan_blackboard:entries(Blackboard),
    Messages = transcript_to_messages(Transcript, AgentId),
    Ctx = #{
        run_id => RunId,
        agent_id => AgentId,
        agent_mod => AgentMod,
        sys => System,
        tools => Specs,
        resolved_tools => ResolvedTools,
        model => Model,
        turn => Turn,
        checkpointer => Checkpointer,
        llm_mod => LlmMod,
        llm_opts => LlmOpts,
        bb => Blackboard,
        stream => Stream,
        guardrails => Guardrails,
        audit => maps:get(audit, AuditCtx, undefined),
        actor => maps:get(actor, AuditCtx, #{})
    },
    loop(Ctx, Messages, 0).

loop(_Ctx, _Msgs, N) when N >= ?MAX_TOOL_ITERATIONS ->
    ok;
loop(Ctx, Msgs, N) ->
    #{
        agent_id := AgentId,
        sys := Sys,
        tools := Tools,
        resolved_tools := ResolvedTools,
        model := Model,
        bb := BB
    } = Ctx,
    case guard(Ctx, input, Msgs) of
        {block, Block} ->
            append_block(Ctx, input, Block);
        {ok, GuardedMsgs} ->
            Req = #{model => Model, system => Sys, tools => Tools, messages => GuardedMsgs},
            case complete_with_idempotency(Ctx, N, Req) of
                {ok, #{stop_reason := end_turn, content := Content}} ->
                    case guard(Ctx, output, collect_text(Content)) of
                        {block, Block} ->
                            append_block(Ctx, output, Block);
                        {ok, Text} ->
                            {ok, _} = gakudan_blackboard:append(BB, {agent, AgentId}, Text),
                            ok
                    end;
                {ok, #{stop_reason := tool_use, content := Content}} ->
                    ToolUses = [B || #{type := tool_use} = B <- Content],
                    ToolResults = run_tools(Ctx, N, ResolvedTools, ToolUses),
                    AssistantTurn = #{role => assistant, content => Content},
                    UserTurn = #{role => user, content => ToolResults},
                    loop(Ctx, Msgs ++ [AssistantTurn, UserTurn], N + 1);
                {error, Reason} ->
                    error({llm_error, Reason})
            end
    end.

guard(Ctx, Stage, Payload) ->
    case maps:get(guardrails, Ctx, []) of
        [] ->
            {ok, Payload};
        Guardrails ->
            Base = #{
                run_id => maps:get(run_id, Ctx),
                agent_id => maps:get(agent_id, Ctx),
                turn => maps:get(turn, Ctx)
            },
            case gakudan_guardrail:run(Guardrails, Stage, Payload, Base) of
                {ok, NewPayload, Trail} ->
                    audit_trail(Ctx, Stage, Trail),
                    {ok, NewPayload};
                {block, {Mod, Reason} = Block, Trail} ->
                    audit_trail(Ctx, Stage, Trail),
                    audit_guardrail(Ctx, Stage, guardrail_block, Mod, #{reason => Reason}),
                    {block, Block}
            end
    end.

audit_trail(Ctx, Stage, Trail) ->
    lists:foreach(
        fun({Mod, Decision}) ->
            audit_guardrail(Ctx, Stage, decision_type(Decision), Mod, #{})
        end,
        Trail
    ).

decision_type(allow) -> guardrail_allow;
decision_type(transform) -> guardrail_transform.

audit_guardrail(Ctx, Stage, Type, Mod, Extra) ->
    Base = #{
        run_id => maps:get(run_id, Ctx),
        agent_id => maps:get(agent_id, Ctx),
        turn => maps:get(turn, Ctx),
        actor => maps:get(actor, Ctx, #{})
    },
    Detail = maps:merge(#{guardrail => Mod, stage => Stage}, Extra),
    Event = gakudan_audit:event(Type, Base, Detail),
    gakudan_audit:record(maps:get(audit, Ctx, undefined), Event).

append_block(Ctx, Stage, {Mod, Reason}) ->
    #{run_id := RunId, agent_id := AgentId, turn := Turn, bb := BB} = Ctx,
    Body = iolist_to_binary([
        atom_to_binary(Stage),
        " blocked by ",
        atom_to_binary(Mod),
        ": ",
        io_lib:format("~p", [Reason])
    ]),
    {ok, _} = gakudan_blackboard:append(BB, system, Body),
    telemetry:execute(
        [gakudan, guardrail, block],
        #{system_time => erlang:system_time()},
        #{
            run_id => RunId,
            agent_id => AgentId,
            turn => Turn,
            stage => Stage,
            guardrail => Mod,
            reason => Reason
        }
    ),
    ok.

complete_with_idempotency(Ctx, Iter, Req) ->
    #{
        run_id := RunId,
        agent_id := AgentId,
        turn := Turn,
        checkpointer := Checkpointer,
        llm_mod := LMod,
        llm_opts := LOpts,
        model := Model,
        stream := Stream
    } = Ctx,
    StepId = step_id(RunId, Turn, AgentId, Iter),
    case Checkpointer of
        undefined ->
            stream_with_telemetry(RunId, AgentId, Turn, LMod, Model, Req, LOpts, Stream);
        _ ->
            case gakudan_checkpointer:load_step(Checkpointer, RunId, StepId) of
                {ok, #{response := CachedResp}} ->
                    {ok, CachedResp};
                {error, not_found} ->
                    case
                        stream_with_telemetry(RunId, AgentId, Turn, LMod, Model, Req, LOpts, Stream)
                    of
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

stream_with_telemetry(RunId, AgentId, Turn, LMod, Model, Req, LOpts, Stream) ->
    StartMeta = #{
        run_id => RunId,
        agent_id => AgentId,
        turn => Turn,
        backend => LMod,
        model => Model
    },
    Ref = make_ref(),
    telemetry:execute(
        [gakudan, llm, stream, start],
        #{system_time => erlang:system_time()},
        StartMeta#{request_id => Ref}
    ),
    Parent = self(),
    Collector = spawn_link(fun() ->
        collect_events(Parent, Ref, RunId, AgentId, Stream)
    end),
    Result = telemetry:span(
        [gakudan, llm, request],
        StartMeta,
        fun() ->
            case gakudan_llm:stream(LMod, Req, LOpts#{stream_request_id => Ref}, Collector) of
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
    ),
    Collector ! {gakudan_llm_stream, Ref, drain},
    receive
        {collector_done, Ref, EventCount} ->
            telemetry:execute(
                [gakudan, llm, stream, complete],
                #{events => EventCount},
                StartMeta#{request_id => Ref, outcome => stream_outcome(Result)}
            )
    after 1000 ->
        ok
    end,
    Result.

stream_outcome({ok, _}) -> ok;
stream_outcome({error, _}) -> error.

collect_events(Parent, Ref, RunId, AgentId, Stream) ->
    collect_events_loop(Parent, Ref, RunId, AgentId, Stream, 0).

collect_events_loop(Parent, Ref, RunId, AgentId, Stream, N) ->
    receive
        {gakudan_llm_stream, Ref, drain} ->
            Parent ! {collector_done, Ref, N};
        {gakudan_llm_stream, Ref, Event} = _Msg ->
            maybe_publish(Stream, AgentId, Ref, Event),
            maybe_token_telemetry(RunId, AgentId, Ref, Event),
            collect_events_loop(Parent, Ref, RunId, AgentId, Stream, N + 1)
    end.

maybe_publish(undefined, _AgentId, _Ref, _Event) ->
    ok;
maybe_publish(Stream, AgentId, Ref, Event) ->
    Meta = #{agent_id => AgentId, request_id => Ref},
    gakudan_stream:publish(Stream, Meta, Event).

maybe_token_telemetry(RunId, AgentId, Ref, {text_delta, Delta}) ->
    telemetry:execute(
        [gakudan, llm, stream, token],
        #{bytes => byte_size(Delta)},
        #{run_id => RunId, agent_id => AgentId, request_id => Ref, event_type => text_delta}
    );
maybe_token_telemetry(RunId, AgentId, Ref, {tool_use_input_delta, #{partial_json := J}}) ->
    telemetry:execute(
        [gakudan, llm, stream, token],
        #{bytes => byte_size(J)},
        #{
            run_id => RunId,
            agent_id => AgentId,
            request_id => Ref,
            event_type => tool_use_input_delta
        }
    );
maybe_token_telemetry(_RunId, _AgentId, _Ref, _Event) ->
    ok.

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

run_tools(Ctx, Iter, ResolvedTools, ToolUses) ->
    NameMap = maps:from_list([
        {maps:get(name, maps:get(spec, R)), R}
     || R <- ResolvedTools
    ]),
    lists:map(
        fun(#{id := Id, name := Name, input := Input}) ->
            case maps:find(Name, NameMap) of
                {ok, Resolved} ->
                    tool_result_block(Id, run_one_tool(Ctx, Iter, Id, Name, Resolved, Input));
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

%% Run a single tool, caching its result under a deterministic key so a
%% resumed turn replays the result instead of re-running the tool (ADR
%% 0009). Errors are not cached: a failed tool retries on resume.
run_one_tool(Ctx, Iter, ToolUseId, Name, #{run := RunFun, idempotent := Idempotent}, Input) ->
    #{
        run_id := RunId,
        agent_id := AgentId,
        turn := Turn,
        checkpointer := Checkpointer
    } = Ctx,
    case cacheable(Checkpointer, Idempotent) of
        false ->
            run_tool_with_telemetry(RunId, AgentId, Turn, Name, RunFun, Input);
        true ->
            ToolStepId = tool_step_id(RunId, Turn, AgentId, Iter, ToolUseId),
            case gakudan_checkpointer:load_tool_result(Checkpointer, RunId, ToolStepId) of
                {ok, #{output := Cached}} ->
                    {ok, Cached};
                {error, not_found} ->
                    case run_tool_with_telemetry(RunId, AgentId, Turn, Name, RunFun, Input) of
                        {ok, Output} = Ok ->
                            persist_tool_result(
                                Checkpointer, RunId, ToolStepId, AgentId, Turn, Name, Output
                            ),
                            Ok;
                        {error, _} = Err ->
                            Err
                    end
            end
    end.

cacheable(undefined, _Idempotent) -> false;
cacheable(_Checkpointer, Idempotent) -> Idempotent.

tool_result_block(Id, {ok, Output}) ->
    #{type => tool_result, tool_use_id => Id, content => to_text(Output)};
tool_result_block(Id, {error, Reason}) ->
    #{
        type => tool_result,
        tool_use_id => Id,
        is_error => true,
        content => iolist_to_binary(io_lib:format("error: ~p", [Reason]))
    }.

tool_step_id(RunId, Turn, AgentId, Iter, ToolUseId) ->
    Input = iolist_to_binary([
        RunId,
        $|,
        integer_to_binary(Turn),
        $|,
        atom_to_binary(AgentId),
        $|,
        integer_to_binary(Iter),
        $|,
        ToolUseId
    ]),
    binary:encode_hex(crypto:hash(sha256, Input), lowercase).

persist_tool_result(Checkpointer, RunId, ToolStepId, AgentId, Turn, Name, Output) ->
    Record = #{
        run_id => RunId,
        tool_step_id => ToolStepId,
        agent_id => AgentId,
        turn => Turn,
        tool_name => Name,
        output => Output,
        inserted_at => erlang:system_time(millisecond)
    },
    _ = gakudan_checkpointer:save_tool_result(Checkpointer, Record),
    ok.

run_tool_with_telemetry(RunId, AgentId, Turn, Name, RunFun, Input) ->
    StartMeta = #{run_id => RunId, agent_id => AgentId, turn => Turn, tool => Name},
    telemetry:span(
        [gakudan, tool, run],
        StartMeta,
        fun() ->
            case safe_run_tool(RunFun, Input) of
                {ok, _} = Ok -> {Ok, StartMeta#{outcome => ok}};
                {error, Reason} = Err -> {Err, StartMeta#{outcome => error, reason => Reason}}
            end
        end
    ).

safe_run_tool(RunFun, Input) ->
    try
        RunFun(Input)
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.
