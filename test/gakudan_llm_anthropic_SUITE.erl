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
    no_api_key_returns_error/1
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
        no_api_key_returns_error
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
