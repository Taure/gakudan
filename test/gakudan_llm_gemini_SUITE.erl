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
    response_text_only_is_end_turn/1,
    response_with_function_call_is_tool_use/1,
    response_usage_is_forwarded/1,
    response_without_usage_omits_field/1,
    response_with_empty_candidates_is_empty/1,
    no_api_key_returns_error/1
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
        response_text_only_is_end_turn,
        response_with_function_call_is_tool_use,
        response_usage_is_forwarded,
        response_without_usage_omits_field,
        response_with_empty_candidates_is_empty,
        no_api_key_returns_error
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
