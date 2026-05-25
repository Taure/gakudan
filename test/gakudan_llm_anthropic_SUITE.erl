-module(gakudan_llm_anthropic_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([
    empty_system_passes_through/1,
    non_empty_system_gets_cache_control/1,
    empty_tools_pass_through/1,
    single_tool_gets_cache_control/1,
    only_last_tool_gets_cache_control/1,
    build_body_caches_system_and_tools/1,
    build_body_with_no_tools_omits_tools_key/1,
    parse_response_surfaces_cache_creation_tokens/1,
    parse_response_surfaces_cache_read_tokens/1,
    parse_response_omits_cache_fields_when_absent/1,
    parse_response_handles_missing_usage/1,
    no_api_key_returns_error/1,
    sse_parser_splits_complete_events/1,
    sse_parser_holds_partial_event_in_acc/1,
    sse_parser_ignores_event_without_data/1,
    apply_event_accumulates_text_delta/1,
    apply_event_accumulates_tool_use_partial_json/1,
    apply_event_records_stop_reason_and_usage/1,
    e2e_text_only_stream/1,
    e2e_stream_split_across_chunks/1,
    e2e_tool_use_stream/1
]).

all() ->
    [
        empty_system_passes_through,
        non_empty_system_gets_cache_control,
        empty_tools_pass_through,
        single_tool_gets_cache_control,
        only_last_tool_gets_cache_control,
        build_body_caches_system_and_tools,
        build_body_with_no_tools_omits_tools_key,
        parse_response_surfaces_cache_creation_tokens,
        parse_response_surfaces_cache_read_tokens,
        parse_response_omits_cache_fields_when_absent,
        parse_response_handles_missing_usage,
        no_api_key_returns_error,
        sse_parser_splits_complete_events,
        sse_parser_holds_partial_event_in_acc,
        sse_parser_ignores_event_without_data,
        apply_event_accumulates_text_delta,
        apply_event_accumulates_tool_use_partial_json,
        apply_event_records_stop_reason_and_usage,
        e2e_text_only_stream,
        e2e_stream_split_across_chunks,
        e2e_tool_use_stream
    ].

empty_system_passes_through(_Config) ->
    ?assertEqual(<<>>, gakudan_llm_anthropic:system_with_cache(<<>>)).

non_empty_system_gets_cache_control(_Config) ->
    [Block] = gakudan_llm_anthropic:system_with_cache(~"You are terse."),
    ?assertEqual(text, maps:get(type, Block)),
    ?assertEqual(~"You are terse.", maps:get(text, Block)),
    ?assertEqual(#{type => ephemeral}, maps:get(cache_control, Block)).

empty_tools_pass_through(_Config) ->
    ?assertEqual([], gakudan_llm_anthropic:tools_with_cache([])).

single_tool_gets_cache_control(_Config) ->
    Tool = #{name => ~"echo", description => ~"Echo.", input_schema => #{}},
    [Cached] = gakudan_llm_anthropic:tools_with_cache([Tool]),
    ?assertEqual(#{type => ephemeral}, maps:get(cache_control, Cached)),
    ?assertEqual(~"echo", maps:get(name, Cached)).

only_last_tool_gets_cache_control(_Config) ->
    Tools = [
        #{name => ~"a", description => ~"A", input_schema => #{}},
        #{name => ~"b", description => ~"B", input_schema => #{}},
        #{name => ~"c", description => ~"C", input_schema => #{}}
    ],
    [A, B, C] = gakudan_llm_anthropic:tools_with_cache(Tools),
    ?assertNot(maps:is_key(cache_control, A)),
    ?assertNot(maps:is_key(cache_control, B)),
    ?assertEqual(#{type => ephemeral}, maps:get(cache_control, C)).

build_body_caches_system_and_tools(_Config) ->
    Body = gakudan_llm_anthropic:build_body(
        #{
            model => ~"claude-sonnet-4-6",
            system => ~"You are an agent.",
            tools => [
                #{name => ~"echo", description => ~"Echo.", input_schema => #{}}
            ],
            messages => [#{role => user, content => ~"hi"}]
        },
        #{}
    ),
    [SystemBlock] = maps:get(system, Body),
    ?assertEqual(#{type => ephemeral}, maps:get(cache_control, SystemBlock)),
    [ToolBlock] = maps:get(tools, Body),
    ?assertEqual(#{type => ephemeral}, maps:get(cache_control, ToolBlock)),
    ?assertEqual(~"claude-sonnet-4-6", maps:get(model, Body)).

build_body_with_no_tools_omits_tools_key(_Config) ->
    Body = gakudan_llm_anthropic:build_body(
        #{
            model => ~"claude-sonnet-4-6",
            system => ~"You are an agent.",
            tools => [],
            messages => [#{role => user, content => ~"hi"}]
        },
        #{}
    ),
    ?assertNot(maps:is_key(tools, Body)).

parse_response_surfaces_cache_creation_tokens(_Config) ->
    Body = iolist_to_binary(
        json:encode(#{
            content => [#{type => ~"text", text => ~"hi"}],
            stop_reason => ~"end_turn",
            usage => #{
                input_tokens => 10,
                output_tokens => 5,
                cache_creation_input_tokens => 42
            }
        })
    ),
    {ok, Resp} = gakudan_llm_anthropic:parse_response(Body),
    Usage = maps:get(usage, Resp),
    ?assertEqual(42, maps:get(cache_creation_input_tokens, Usage)),
    ?assertNot(maps:is_key(cache_read_input_tokens, Usage)).

parse_response_surfaces_cache_read_tokens(_Config) ->
    Body = iolist_to_binary(
        json:encode(#{
            content => [#{type => ~"text", text => ~"hi"}],
            stop_reason => ~"end_turn",
            usage => #{
                input_tokens => 10,
                output_tokens => 5,
                cache_read_input_tokens => 99
            }
        })
    ),
    {ok, Resp} = gakudan_llm_anthropic:parse_response(Body),
    Usage = maps:get(usage, Resp),
    ?assertEqual(99, maps:get(cache_read_input_tokens, Usage)),
    ?assertNot(maps:is_key(cache_creation_input_tokens, Usage)).

parse_response_omits_cache_fields_when_absent(_Config) ->
    Body = iolist_to_binary(
        json:encode(#{
            content => [#{type => ~"text", text => ~"hi"}],
            stop_reason => ~"end_turn",
            usage => #{input_tokens => 10, output_tokens => 5}
        })
    ),
    {ok, Resp} = gakudan_llm_anthropic:parse_response(Body),
    Usage = maps:get(usage, Resp),
    ?assertEqual(10, maps:get(input_tokens, Usage)),
    ?assertEqual(5, maps:get(output_tokens, Usage)),
    ?assertNot(maps:is_key(cache_creation_input_tokens, Usage)),
    ?assertNot(maps:is_key(cache_read_input_tokens, Usage)).

parse_response_handles_missing_usage(_Config) ->
    Body = iolist_to_binary(
        json:encode(#{
            content => [#{type => ~"text", text => ~"hi"}],
            stop_reason => ~"end_turn"
        })
    ),
    {ok, Resp} = gakudan_llm_anthropic:parse_response(Body),
    ?assertNot(maps:is_key(usage, Resp)).

no_api_key_returns_error(_Config) ->
    os:unsetenv("ANTHROPIC_API_KEY"),
    Req = #{
        model => ~"claude-sonnet-4-6",
        system => ~"sys",
        tools => [],
        messages => [#{role => user, content => ~"hi"}]
    },
    ?assertEqual({error, no_api_key}, gakudan_llm_anthropic:complete(Req, #{})).

sse_parser_splits_complete_events(_Config) ->
    Chunk = iolist_to_binary([
        ~"event: message_start\n",
        ~"data: {\"type\":\"message_start\"}\n\n",
        ~"event: ping\n",
        ~"data: {\"type\":\"ping\"}\n\n"
    ]),
    {Events, Rest} = gakudan_llm_anthropic:parse_sse(Chunk, <<>>),
    ?assertEqual(<<>>, Rest),
    ?assertEqual(2, length(Events)),
    [E1, E2] = Events,
    ?assertEqual(~"message_start", maps:get(~"type", E1)),
    ?assertEqual(~"ping", maps:get(~"type", E2)).

sse_parser_holds_partial_event_in_acc(_Config) ->
    Chunk1 = iolist_to_binary([
        ~"event: content_block_delta\n",
        ~"data: {\"type\":\"content_block_delta\",\"index\":0,",
        ~"\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}"
    ]),
    {Events1, Acc1} = gakudan_llm_anthropic:parse_sse(Chunk1, <<>>),
    ?assertEqual([], Events1),
    {Events2, Acc2} = gakudan_llm_anthropic:parse_sse(~"\n\n", Acc1),
    ?assertEqual(<<>>, Acc2),
    ?assertEqual(1, length(Events2)),
    [E] = Events2,
    ?assertEqual(~"content_block_delta", maps:get(~"type", E)).

sse_parser_ignores_event_without_data(_Config) ->
    %% A comment-only event keeps the connection alive but carries no JSON.
    Chunk = ~": keepalive\n\n",
    {Events, Rest} = gakudan_llm_anthropic:parse_sse(Chunk, <<>>),
    ?assertEqual(<<>>, Rest),
    ?assertEqual([], Events).

apply_event_accumulates_text_delta(_Config) ->
    Acc0 = #{
        blocks => #{},
        stop_reason => undefined,
        usage => #{input_tokens => 0, output_tokens => 0}
    },
    Start = #{
        ~"type" => ~"content_block_start",
        ~"index" => 0,
        ~"content_block" => #{~"type" => ~"text"}
    },
    Delta1 = #{
        ~"type" => ~"content_block_delta",
        ~"index" => 0,
        ~"delta" => #{~"type" => ~"text_delta", ~"text" => ~"hel"}
    },
    Delta2 = #{
        ~"type" => ~"content_block_delta",
        ~"index" => 0,
        ~"delta" => #{~"type" => ~"text_delta", ~"text" => ~"lo"}
    },
    Acc1 = gakudan_llm_anthropic:apply_anthropic_event(Start, Acc0),
    Acc2 = gakudan_llm_anthropic:apply_anthropic_event(Delta1, Acc1),
    Acc3 = gakudan_llm_anthropic:apply_anthropic_event(Delta2, Acc2),
    Block = maps:get(0, maps:get(blocks, Acc3)),
    ?assertEqual(text, maps:get(type, Block)),
    ?assertEqual(~"hello", maps:get(text, Block)).

apply_event_accumulates_tool_use_partial_json(_Config) ->
    Acc0 = #{
        blocks => #{},
        stop_reason => undefined,
        usage => #{input_tokens => 0, output_tokens => 0}
    },
    Start = #{
        ~"type" => ~"content_block_start",
        ~"index" => 1,
        ~"content_block" => #{
            ~"type" => ~"tool_use",
            ~"id" => ~"toolu_abc",
            ~"name" => ~"echo"
        }
    },
    Delta1 = #{
        ~"type" => ~"content_block_delta",
        ~"index" => 1,
        ~"delta" => #{~"type" => ~"input_json_delta", ~"partial_json" => ~"{\"x\":"}
    },
    Delta2 = #{
        ~"type" => ~"content_block_delta",
        ~"index" => 1,
        ~"delta" => #{~"type" => ~"input_json_delta", ~"partial_json" => ~"1}"}
    },
    Acc1 = gakudan_llm_anthropic:apply_anthropic_event(Start, Acc0),
    Acc2 = gakudan_llm_anthropic:apply_anthropic_event(Delta1, Acc1),
    Acc3 = gakudan_llm_anthropic:apply_anthropic_event(Delta2, Acc2),
    Block = maps:get(1, maps:get(blocks, Acc3)),
    ?assertEqual(tool_use, maps:get(type, Block)),
    ?assertEqual(~"toolu_abc", maps:get(id, Block)),
    ?assertEqual(~"echo", maps:get(name, Block)),
    ?assertEqual(~"{\"x\":1}", maps:get(partial_json, Block)).

apply_event_records_stop_reason_and_usage(_Config) ->
    Acc0 = #{
        blocks => #{},
        stop_reason => undefined,
        usage => #{input_tokens => 5, output_tokens => 0}
    },
    Event = #{
        ~"type" => ~"message_delta",
        ~"delta" => #{~"stop_reason" => ~"end_turn"},
        ~"usage" => #{~"output_tokens" => 12}
    },
    Acc = gakudan_llm_anthropic:apply_anthropic_event(Event, Acc0),
    ?assertEqual(end_turn, maps:get(stop_reason, Acc)),
    Usage = maps:get(usage, Acc),
    ?assertEqual(5, maps:get(input_tokens, Usage)),
    ?assertEqual(12, maps:get(output_tokens, Usage)).

%% End-to-end pipeline: canned SSE bytes -> subscriber events + finalised response.

e2e_text_only_stream(_Config) ->
    Ref = make_ref(),
    SSE = canned_text_stream(),
    {Pending, Acc} = drive_stream(Ref, [SSE]),
    ?assertEqual(<<>>, Pending),
    Resp = gakudan_llm_anthropic:finalise(Acc),
    %% subscriber receives start/text_delta sequence/message_delta in order
    Events = collect_stream_events(Ref, 200),
    Texts = [T || {text_delta, T} <- Events],
    ?assertEqual([~"Hello, ", ~"world", ~"!"], Texts),
    ?assert(
        lists:any(
            fun
                ({message_delta, _}) -> true;
                (_) -> false
            end,
            Events
        )
    ),
    %% finalised response
    ?assertEqual(end_turn, maps:get(stop_reason, Resp)),
    [#{type := text, text := Full}] = maps:get(content, Resp),
    ?assertEqual(~"Hello, world!", Full),
    Usage = maps:get(usage, Resp),
    ?assertEqual(8, maps:get(input_tokens, Usage)),
    ?assertEqual(5, maps:get(output_tokens, Usage)).

e2e_stream_split_across_chunks(_Config) ->
    %% Feed the same bytes but split inside an SSE event boundary.
    Ref = make_ref(),
    Full = canned_text_stream(),
    Mid = byte_size(Full) div 2,
    <<Chunk1:Mid/binary, Chunk2/binary>> = Full,
    {Pending, Acc} = drive_stream(Ref, [Chunk1, Chunk2]),
    ?assertEqual(<<>>, Pending),
    Resp = gakudan_llm_anthropic:finalise(Acc),
    Events = collect_stream_events(Ref, 200),
    Texts = [T || {text_delta, T} <- Events],
    ?assertEqual([~"Hello, ", ~"world", ~"!"], Texts),
    [#{type := text, text := Joined}] = maps:get(content, Resp),
    ?assertEqual(~"Hello, world!", Joined).

e2e_tool_use_stream(_Config) ->
    Ref = make_ref(),
    SSE = canned_tool_use_stream(),
    {_Pending, Acc} = drive_stream(Ref, [SSE]),
    Resp = gakudan_llm_anthropic:finalise(Acc),
    Events = collect_stream_events(Ref, 200),
    %% subscriber sees tool_use_start then input_json deltas
    ?assert(
        lists:any(
            fun
                ({tool_use_start, #{id := ~"toolu_abc", name := ~"echo"}}) -> true;
                (_) -> false
            end,
            Events
        )
    ),
    JsonDeltas = [J || {tool_use_input_delta, #{partial_json := J}} <- Events],
    ?assertEqual([~"{\"x\":", ~"1}"], JsonDeltas),
    %% finalised response: tool_use stop_reason, input decoded from partial JSON
    ?assertEqual(tool_use, maps:get(stop_reason, Resp)),
    [Block] = maps:get(content, Resp),
    ?assertEqual(tool_use, maps:get(type, Block)),
    ?assertEqual(~"toolu_abc", maps:get(id, Block)),
    ?assertEqual(~"echo", maps:get(name, Block)),
    ?assertEqual(#{~"x" => 1}, maps:get(input, Block)).

%% drives feed_stream_chunk/4 across a list of chunks, returning final {pending, stream_acc}.
%% Sends subscriber messages to a child collector keyed off Ref.
drive_stream(Ref, Chunks) ->
    Self = self(),
    Sub = spawn_link(fun() ->
        Self ! {collector_ready, Ref},
        collector_loop(Self, Ref, [])
    end),
    receive
        {collector_ready, Ref} -> ok
    after 1000 ->
        error(collector_timeout)
    end,
    Acc0 = gakudan_llm_anthropic:fresh_stream_acc(),
    {_, Pending, Acc} = lists:foldl(
        fun(Chunk, {Subscriber, P, A}) ->
            {NewP, NewA} = gakudan_llm_anthropic:feed_stream_chunk(Chunk, P, A, {Subscriber, Ref}),
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

collector_loop(Parent, Ref, Acc) ->
    receive
        {gakudan_llm_stream, Ref, Event} ->
            collector_loop(Parent, Ref, [Event | Acc]);
        {drain, Ref, From} ->
            From ! {drained, Ref, lists:reverse(Acc)}
    end.

collect_stream_events(Ref, _Timeout) ->
    case erase({drained, Ref}) of
        undefined -> [];
        Events -> Events
    end.

canned_text_stream() ->
    Events = [
        {~"message_start", #{
            ~"type" => ~"message_start",
            ~"message" => #{~"usage" => #{~"input_tokens" => 8, ~"output_tokens" => 0}}
        }},
        {~"content_block_start", #{
            ~"type" => ~"content_block_start",
            ~"index" => 0,
            ~"content_block" => #{~"type" => ~"text", ~"text" => ~""}
        }},
        {~"content_block_delta", #{
            ~"type" => ~"content_block_delta",
            ~"index" => 0,
            ~"delta" => #{~"type" => ~"text_delta", ~"text" => ~"Hello, "}
        }},
        {~"content_block_delta", #{
            ~"type" => ~"content_block_delta",
            ~"index" => 0,
            ~"delta" => #{~"type" => ~"text_delta", ~"text" => ~"world"}
        }},
        {~"content_block_delta", #{
            ~"type" => ~"content_block_delta",
            ~"index" => 0,
            ~"delta" => #{~"type" => ~"text_delta", ~"text" => ~"!"}
        }},
        {~"content_block_stop", #{~"type" => ~"content_block_stop", ~"index" => 0}},
        {~"message_delta", #{
            ~"type" => ~"message_delta",
            ~"delta" => #{~"stop_reason" => ~"end_turn"},
            ~"usage" => #{~"output_tokens" => 5}
        }},
        {~"message_stop", #{~"type" => ~"message_stop"}}
    ],
    encode_sse(Events).

canned_tool_use_stream() ->
    Events = [
        {~"message_start", #{
            ~"type" => ~"message_start",
            ~"message" => #{~"usage" => #{~"input_tokens" => 12, ~"output_tokens" => 0}}
        }},
        {~"content_block_start", #{
            ~"type" => ~"content_block_start",
            ~"index" => 0,
            ~"content_block" => #{
                ~"type" => ~"tool_use",
                ~"id" => ~"toolu_abc",
                ~"name" => ~"echo"
            }
        }},
        {~"content_block_delta", #{
            ~"type" => ~"content_block_delta",
            ~"index" => 0,
            ~"delta" => #{~"type" => ~"input_json_delta", ~"partial_json" => ~"{\"x\":"}
        }},
        {~"content_block_delta", #{
            ~"type" => ~"content_block_delta",
            ~"index" => 0,
            ~"delta" => #{~"type" => ~"input_json_delta", ~"partial_json" => ~"1}"}
        }},
        {~"content_block_stop", #{~"type" => ~"content_block_stop", ~"index" => 0}},
        {~"message_delta", #{
            ~"type" => ~"message_delta",
            ~"delta" => #{~"stop_reason" => ~"tool_use"},
            ~"usage" => #{~"output_tokens" => 7}
        }},
        {~"message_stop", #{~"type" => ~"message_stop"}}
    ],
    encode_sse(Events).

encode_sse(Events) ->
    iolist_to_binary(
        [
            [<<"event: ">>, Name, <<"\ndata: ">>, json:encode(Json), <<"\n\n">>]
         || {Name, Json} <- Events
        ]
    ).
