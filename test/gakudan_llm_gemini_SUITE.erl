-module(gakudan_llm_gemini_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([
    text_only_request_omits_tools_and_system/1,
    system_prompt_lands_in_system_instruction/1,
    user_message_becomes_user_role/1,
    assistant_message_becomes_model_role/1,
    tool_use_becomes_function_call/1,
    tool_result_recovers_name_from_prior_tool_use/1,
    tool_result_with_unknown_id_falls_back/1,
    tools_translate_to_function_declarations/1,
    generation_options_land_in_generation_config/1,
    tool_choice_maps_to_function_calling_config/1,
    response_format_maps_to_response_schema/1,
    response_text_only_is_end_turn/1,
    response_with_function_call_is_tool_use/1,
    response_usage_is_forwarded/1,
    response_without_usage_omits_field/1,
    response_with_empty_candidates_is_empty/1,
    no_api_key_returns_error/1,
    apply_event_accumulates_text_across_chunks/1,
    apply_event_records_finish_reason/1,
    apply_event_creates_tool_use_block/1,
    apply_event_flushes_text_before_tool_use/1,
    finalise_defaults_stop_reason_when_tool_present/1,
    e2e_text_only_stream/1,
    e2e_stream_split_across_chunks/1,
    e2e_tool_use_stream/1
]).

all() ->
    [
        text_only_request_omits_tools_and_system,
        system_prompt_lands_in_system_instruction,
        user_message_becomes_user_role,
        assistant_message_becomes_model_role,
        tool_use_becomes_function_call,
        tool_result_recovers_name_from_prior_tool_use,
        tool_result_with_unknown_id_falls_back,
        tools_translate_to_function_declarations,
        generation_options_land_in_generation_config,
        tool_choice_maps_to_function_calling_config,
        response_format_maps_to_response_schema,
        response_text_only_is_end_turn,
        response_with_function_call_is_tool_use,
        response_usage_is_forwarded,
        response_without_usage_omits_field,
        response_with_empty_candidates_is_empty,
        no_api_key_returns_error,
        apply_event_accumulates_text_across_chunks,
        apply_event_records_finish_reason,
        apply_event_creates_tool_use_block,
        apply_event_flushes_text_before_tool_use,
        finalise_defaults_stop_reason_when_tool_present,
        e2e_text_only_stream,
        e2e_stream_split_across_chunks,
        e2e_tool_use_stream
    ].

text_only_request_omits_tools_and_system(_Config) ->
    Body = gakudan_llm_gemini:build_body(
        #{
            model => ~"gemini-2.5-flash",
            system => <<>>,
            tools => [],
            messages => [#{role => user, content => ~"hi"}]
        },
        #{}
    ),
    ?assertNot(maps:is_key(systemInstruction, Body)),
    ?assertNot(maps:is_key(tools, Body)),
    ?assertEqual(
        [#{role => ~"user", parts => [#{text => ~"hi"}]}],
        maps:get(contents, Body)
    ),
    ?assertMatch(#{maxOutputTokens := _}, maps:get(generationConfig, Body)).

system_prompt_lands_in_system_instruction(_Config) ->
    Body = gakudan_llm_gemini:build_body(
        #{
            model => ~"gemini-2.5-flash",
            system => ~"You are terse.",
            tools => [],
            messages => [#{role => user, content => ~"hi"}]
        },
        #{}
    ),
    ?assertEqual(
        #{parts => [#{text => ~"You are terse."}]},
        maps:get(systemInstruction, Body)
    ).

user_message_becomes_user_role(_Config) ->
    [Translated] = gakudan_llm_gemini:translate_messages([
        #{role => user, content => ~"hello"}
    ]),
    ?assertEqual(~"user", maps:get(role, Translated)),
    ?assertEqual([#{text => ~"hello"}], maps:get(parts, Translated)).

assistant_message_becomes_model_role(_Config) ->
    [Translated] = gakudan_llm_gemini:translate_messages([
        #{role => assistant, content => ~"hi back"}
    ]),
    ?assertEqual(~"model", maps:get(role, Translated)),
    ?assertEqual([#{text => ~"hi back"}], maps:get(parts, Translated)).

tool_use_becomes_function_call(_Config) ->
    [Translated] = gakudan_llm_gemini:translate_messages([
        #{
            role => assistant,
            content => [
                #{type => text, text => ~"I'll call a tool"},
                #{
                    type => tool_use,
                    id => ~"tu_1",
                    name => ~"echo_tool",
                    input => #{~"msg" => ~"x"}
                }
            ]
        }
    ]),
    ?assertEqual(~"model", maps:get(role, Translated)),
    [TextPart, FcPart] = maps:get(parts, Translated),
    ?assertEqual(#{text => ~"I'll call a tool"}, TextPart),
    ?assertEqual(
        #{functionCall => #{name => ~"echo_tool", args => #{~"msg" => ~"x"}}},
        FcPart
    ).

tool_result_recovers_name_from_prior_tool_use(_Config) ->
    Translated = gakudan_llm_gemini:translate_messages([
        #{
            role => assistant,
            content => [
                #{
                    type => tool_use,
                    id => ~"tu_42",
                    name => ~"echo_tool",
                    input => #{~"msg" => ~"hi"}
                }
            ]
        },
        #{
            role => user,
            content => [
                #{type => tool_result, tool_use_id => ~"tu_42", content => ~"hi"}
            ]
        }
    ]),
    [_, UserMsg] = Translated,
    [FrPart] = maps:get(parts, UserMsg),
    ?assertEqual(
        #{
            functionResponse => #{
                name => ~"echo_tool",
                response => #{result => ~"hi"}
            }
        },
        FrPart
    ).

tool_result_with_unknown_id_falls_back(_Config) ->
    [Translated] = gakudan_llm_gemini:translate_messages([
        #{
            role => user,
            content => [
                #{type => tool_result, tool_use_id => ~"orphan", content => ~"x"}
            ]
        }
    ]),
    [FrPart] = maps:get(parts, Translated),
    ?assertEqual(~"unknown_tool", maps:get(name, maps:get(functionResponse, FrPart))).

tools_translate_to_function_declarations(_Config) ->
    Tools = [
        #{
            name => ~"echo_tool",
            description => ~"Echoes input.",
            input_schema => #{
                type => ~"object",
                properties => #{msg => #{type => ~"string"}},
                required => [~"msg"]
            }
        }
    ],
    [Group] = gakudan_llm_gemini:translate_tools(Tools),
    ?assert(maps:is_key(functionDeclarations, Group)),
    [Decl] = maps:get(functionDeclarations, Group),
    ?assertEqual(~"echo_tool", maps:get(name, Decl)),
    ?assertEqual(~"Echoes input.", maps:get(description, Decl)),
    ?assertMatch(#{type := ~"object"}, maps:get(parameters, Decl)).

generation_options_land_in_generation_config(_Config) ->
    Body = gakudan_llm_gemini:build_body(
        #{
            model => ~"gemini-2.5-flash",
            system => <<>>,
            tools => [],
            messages => [#{role => user, content => ~"hi"}],
            temperature => 0.5,
            stop_sequences => [~"END"],
            max_tokens => 128
        },
        #{}
    ),
    Cfg = maps:get(generationConfig, Body),
    ?assertEqual(0.5, maps:get(temperature, Cfg)),
    ?assertEqual([~"END"], maps:get(stopSequences, Cfg)),
    ?assertEqual(128, maps:get(maxOutputTokens, Cfg)).

tool_choice_maps_to_function_calling_config(_Config) ->
    Mk = fun(Choice) ->
        Body = gakudan_llm_gemini:build_body(
            #{
                model => ~"m",
                system => <<>>,
                tools => [#{name => ~"echo", description => ~"E", input_schema => #{}}],
                messages => [#{role => user, content => ~"hi"}],
                tool_choice => Choice
            },
            #{}
        ),
        maps:get(functionCallingConfig, maps:get(toolConfig, Body))
    end,
    ?assertEqual(#{mode => ~"AUTO"}, Mk(auto)),
    ?assertEqual(#{mode => ~"ANY"}, Mk(any)),
    ?assertEqual(#{mode => ~"NONE"}, Mk(none)),
    ?assertEqual(#{mode => ~"ANY", allowedFunctionNames => [~"echo"]}, Mk({tool, ~"echo"})).

response_format_maps_to_response_schema(_Config) ->
    Schema = #{type => ~"object", properties => #{x => #{type => ~"integer"}}},
    Body = gakudan_llm_gemini:build_body(
        #{
            model => ~"m",
            system => <<>>,
            tools => [],
            messages => [#{role => user, content => ~"hi"}],
            response_format => Schema
        },
        #{}
    ),
    Cfg = maps:get(generationConfig, Body),
    ?assertEqual(~"application/json", maps:get(responseMimeType, Cfg)),
    ?assertEqual(Schema, maps:get(responseSchema, Cfg)).

response_text_only_is_end_turn(_Config) ->
    Body = iolist_to_binary(
        json:encode(#{
            candidates => [
                #{
                    content => #{
                        role => ~"model",
                        parts => [#{text => ~"a reply"}]
                    },
                    finishReason => ~"STOP"
                }
            ]
        })
    ),
    {ok, Resp} = gakudan_llm_gemini:parse_response(Body),
    ?assertEqual(end_turn, maps:get(stop_reason, Resp)),
    ?assertEqual([#{type => text, text => ~"a reply"}], maps:get(content, Resp)).

response_with_function_call_is_tool_use(_Config) ->
    Body = iolist_to_binary(
        json:encode(#{
            candidates => [
                #{
                    content => #{
                        role => ~"model",
                        parts => [
                            #{text => ~"calling tool"},
                            #{
                                functionCall => #{
                                    name => ~"echo_tool",
                                    args => #{msg => ~"x"}
                                }
                            }
                        ]
                    },
                    finishReason => ~"STOP"
                }
            ]
        })
    ),
    {ok, Resp} = gakudan_llm_gemini:parse_response(Body),
    ?assertEqual(tool_use, maps:get(stop_reason, Resp)),
    [TextBlock, ToolUseBlock] = maps:get(content, Resp),
    ?assertEqual(#{type => text, text => ~"calling tool"}, TextBlock),
    ?assertMatch(
        #{type := tool_use, name := ~"echo_tool", input := #{~"msg" := ~"x"}},
        ToolUseBlock
    ),
    ?assert(is_binary(maps:get(id, ToolUseBlock))).

response_usage_is_forwarded(_Config) ->
    Body = iolist_to_binary(
        json:encode(#{
            candidates => [
                #{
                    content => #{role => ~"model", parts => [#{text => ~"hi"}]},
                    finishReason => ~"STOP"
                }
            ],
            usageMetadata => #{
                promptTokenCount => 42,
                candidatesTokenCount => 7,
                totalTokenCount => 49
            }
        })
    ),
    {ok, Resp} = gakudan_llm_gemini:parse_response(Body),
    ?assertEqual(
        #{input_tokens => 42, output_tokens => 7},
        maps:get(usage, Resp)
    ).

response_without_usage_omits_field(_Config) ->
    Body = iolist_to_binary(
        json:encode(#{
            candidates => [
                #{
                    content => #{role => ~"model", parts => [#{text => ~"hi"}]},
                    finishReason => ~"STOP"
                }
            ]
        })
    ),
    {ok, Resp} = gakudan_llm_gemini:parse_response(Body),
    ?assertNot(maps:is_key(usage, Resp)).

response_with_empty_candidates_is_empty(_Config) ->
    Body = iolist_to_binary(json:encode(#{candidates => []})),
    {ok, Resp} = gakudan_llm_gemini:parse_response(Body),
    ?assertEqual(end_turn, maps:get(stop_reason, Resp)),
    ?assertEqual([], maps:get(content, Resp)).

no_api_key_returns_error(_Config) ->
    os:unsetenv("GEMINI_API_KEY"),
    Req = #{
        model => ~"gemini-2.5-flash",
        system => ~"sys",
        tools => [],
        messages => [#{role => user, content => ~"hi"}]
    },
    ?assertEqual({error, no_api_key}, gakudan_llm_gemini:complete(Req, #{})).

%%% Streaming - unit %%%

apply_event_accumulates_text_across_chunks(_Config) ->
    Acc0 = gakudan_llm_gemini:fresh_stream_acc(),
    C1 = #{
        ~"candidates" => [#{~"content" => #{~"parts" => [#{~"text" => ~"Hello"}]}}]
    },
    C2 = #{
        ~"candidates" => [#{~"content" => #{~"parts" => [#{~"text" => ~", world!"}]}}]
    },
    Acc1 = gakudan_llm_gemini:apply_gemini_event(C1, Acc0),
    Acc2 = gakudan_llm_gemini:apply_gemini_event(C2, Acc1),
    ?assertEqual(~"Hello, world!", maps:get(current_text, Acc2)).

apply_event_records_finish_reason(_Config) ->
    Acc0 = gakudan_llm_gemini:fresh_stream_acc(),
    Chunk = #{
        ~"candidates" => [
            #{
                ~"content" => #{~"parts" => [#{~"text" => ~"done"}]},
                ~"finishReason" => ~"STOP"
            }
        ],
        ~"usageMetadata" => #{
            ~"promptTokenCount" => 6,
            ~"candidatesTokenCount" => 4
        }
    },
    Acc = gakudan_llm_gemini:apply_gemini_event(Chunk, Acc0),
    ?assertEqual(end_turn, maps:get(stop_reason, Acc)),
    Usage = maps:get(usage, Acc),
    ?assertEqual(6, maps:get(input_tokens, Usage)),
    ?assertEqual(4, maps:get(output_tokens, Usage)).

apply_event_creates_tool_use_block(_Config) ->
    Acc0 = gakudan_llm_gemini:fresh_stream_acc(),
    Chunk = #{
        ~"candidates" => [
            #{
                ~"content" => #{
                    ~"parts" => [
                        #{
                            ~"functionCall" => #{
                                ~"name" => ~"echo",
                                ~"args" => #{~"x" => 1}
                            }
                        }
                    ]
                },
                ~"finishReason" => ~"TOOL_CALL"
            }
        ]
    },
    Acc = gakudan_llm_gemini:apply_gemini_event(Chunk, Acc0),
    ?assertEqual(tool_use, maps:get(stop_reason, Acc)),
    [Block] = maps:get(blocks, Acc),
    ?assertEqual(tool_use, maps:get(type, Block)),
    ?assertEqual(~"echo", maps:get(name, Block)),
    ?assertEqual(#{~"x" => 1}, maps:get(input, Block)).

apply_event_flushes_text_before_tool_use(_Config) ->
    Acc0 = gakudan_llm_gemini:fresh_stream_acc(),
    Chunk = #{
        ~"candidates" => [
            #{
                ~"content" => #{
                    ~"parts" => [
                        #{~"text" => ~"Let me check: "},
                        #{
                            ~"functionCall" => #{
                                ~"name" => ~"lookup",
                                ~"args" => #{}
                            }
                        }
                    ]
                }
            }
        ]
    },
    Acc = gakudan_llm_gemini:apply_gemini_event(Chunk, Acc0),
    Blocks = maps:get(blocks, Acc),
    ?assertEqual(2, length(Blocks)),
    [Text, Tool] = Blocks,
    ?assertEqual(text, maps:get(type, Text)),
    ?assertEqual(~"Let me check: ", maps:get(text, Text)),
    ?assertEqual(tool_use, maps:get(type, Tool)),
    ?assertEqual(~"lookup", maps:get(name, Tool)).

finalise_defaults_stop_reason_when_tool_present(_Config) ->
    Acc0 = gakudan_llm_gemini:fresh_stream_acc(),
    %% No finishReason in the chunk, but a tool call exists.
    Chunk = #{
        ~"candidates" => [
            #{
                ~"content" => #{
                    ~"parts" => [
                        #{
                            ~"functionCall" => #{
                                ~"name" => ~"x",
                                ~"args" => #{}
                            }
                        }
                    ]
                }
            }
        ]
    },
    Acc = gakudan_llm_gemini:apply_gemini_event(Chunk, Acc0),
    Resp = gakudan_llm_gemini:finalise(Acc),
    ?assertEqual(tool_use, maps:get(stop_reason, Resp)).

%%% Streaming - end-to-end %%%

e2e_text_only_stream(_Config) ->
    Ref = make_ref(),
    SSE = canned_text_stream(),
    {Pending, Acc} = drive_stream(Ref, [SSE]),
    ?assertEqual(<<>>, Pending),
    Resp = gakudan_llm_gemini:finalise(Acc),
    Events = collect_stream_events(Ref),
    Texts = [T || {text_delta, T} <- Events],
    ?assertEqual([~"Hello", ~", ", ~"world!"], Texts),
    ?assert(
        lists:any(
            fun
                ({message_delta, _}) -> true;
                (_) -> false
            end,
            Events
        )
    ),
    [#{type := text, text := Full}] = maps:get(content, Resp),
    ?assertEqual(~"Hello, world!", Full),
    ?assertEqual(end_turn, maps:get(stop_reason, Resp)),
    Usage = maps:get(usage, Resp),
    ?assertEqual(8, maps:get(input_tokens, Usage)),
    ?assertEqual(5, maps:get(output_tokens, Usage)).

e2e_stream_split_across_chunks(_Config) ->
    Ref = make_ref(),
    Full = canned_text_stream(),
    Mid = byte_size(Full) div 2,
    <<Chunk1:Mid/binary, Chunk2/binary>> = Full,
    {Pending, Acc} = drive_stream(Ref, [Chunk1, Chunk2]),
    ?assertEqual(<<>>, Pending),
    Resp = gakudan_llm_gemini:finalise(Acc),
    Events = collect_stream_events(Ref),
    Texts = [T || {text_delta, T} <- Events],
    ?assertEqual([~"Hello", ~", ", ~"world!"], Texts),
    [#{type := text, text := Joined}] = maps:get(content, Resp),
    ?assertEqual(~"Hello, world!", Joined).

e2e_tool_use_stream(_Config) ->
    Ref = make_ref(),
    SSE = canned_tool_use_stream(),
    {_Pending, Acc} = drive_stream(Ref, [SSE]),
    Resp = gakudan_llm_gemini:finalise(Acc),
    Events = collect_stream_events(Ref),
    ?assert(
        lists:any(
            fun
                ({tool_use_start, #{name := ~"echo"}}) -> true;
                (_) -> false
            end,
            Events
        )
    ),
    [Json] = [J || {tool_use_input_delta, #{partial_json := J}} <- Events],
    ?assertEqual(#{~"x" => 1}, json:decode(Json)),
    ?assertEqual(tool_use, maps:get(stop_reason, Resp)),
    [Block] = maps:get(content, Resp),
    ?assertEqual(tool_use, maps:get(type, Block)),
    ?assertEqual(~"echo", maps:get(name, Block)),
    ?assertEqual(#{~"x" => 1}, maps:get(input, Block)).

%% Helpers

drive_stream(Ref, Chunks) ->
    Self = self(),
    Sub = spawn_link(fun() ->
        Self ! {collector_ready, Ref},
        collector_loop(Ref, [])
    end),
    receive
        {collector_ready, Ref} -> ok
    after 1000 ->
        error(collector_timeout)
    end,
    Acc0 = gakudan_llm_gemini:fresh_stream_acc(),
    {_, Pending, Acc} = lists:foldl(
        fun(Chunk, {Subscriber, P, A}) ->
            {NewP, NewA} = gakudan_llm_gemini:feed_stream_chunk(
                Chunk, P, A, {Subscriber, Ref}
            ),
            {Subscriber, NewP, NewA}
        end,
        {Sub, <<>>, Acc0},
        Chunks
    ),
    Sub ! {drain, Ref, self()},
    receive
        {drained, Ref, Events} ->
            put({drained, Ref}, Events),
            {Pending, Acc}
    after 1000 ->
        error(drain_timeout)
    end.

collector_loop(Ref, Acc) ->
    receive
        {gakudan_llm_stream, Ref, Event} ->
            collector_loop(Ref, [Event | Acc]);
        {drain, Ref, From} ->
            From ! {drained, Ref, lists:reverse(Acc)}
    end.

collect_stream_events(Ref) ->
    case erase({drained, Ref}) of
        undefined -> [];
        Events -> Events
    end.

canned_text_stream() ->
    Events = [
        #{~"candidates" => [#{~"content" => #{~"parts" => [#{~"text" => ~"Hello"}]}}]},
        #{~"candidates" => [#{~"content" => #{~"parts" => [#{~"text" => ~", "}]}}]},
        #{
            ~"candidates" => [
                #{
                    ~"content" => #{~"parts" => [#{~"text" => ~"world!"}]},
                    ~"finishReason" => ~"STOP"
                }
            ],
            ~"usageMetadata" => #{
                ~"promptTokenCount" => 8,
                ~"candidatesTokenCount" => 5
            }
        }
    ],
    encode_sse(Events).

canned_tool_use_stream() ->
    Events = [
        #{
            ~"candidates" => [
                #{
                    ~"content" => #{
                        ~"parts" => [
                            #{
                                ~"functionCall" => #{
                                    ~"name" => ~"echo",
                                    ~"args" => #{~"x" => 1}
                                }
                            }
                        ]
                    },
                    ~"finishReason" => ~"TOOL_CALL"
                }
            ],
            ~"usageMetadata" => #{
                ~"promptTokenCount" => 12,
                ~"candidatesTokenCount" => 4
            }
        }
    ],
    encode_sse(Events).

encode_sse(Events) ->
    iolist_to_binary(
        [
            [<<"data: ">>, json:encode(E), <<"\n\n">>]
         || E <- Events
        ]
    ).
