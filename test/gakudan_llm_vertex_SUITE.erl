-module(gakudan_llm_vertex_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1]).
-export([
    body_drops_model_adds_version/1,
    body_keeps_messages_and_system/1,
    endpoint_urls/1,
    requires_project/1,
    requires_location/1,
    requires_token/1
]).

all() ->
    [
        body_drops_model_adds_version,
        body_keeps_messages_and_system,
        endpoint_urls,
        requires_project,
        requires_location,
        requires_token
    ].

init_per_suite(Config) ->
    os:unsetenv("GOOGLE_VERTEX_TOKEN"),
    Config.

req() ->
    #{
        model => ~"claude-sonnet-4-5@20250929",
        system => ~"be helpful",
        tools => [],
        messages => [#{role => user, content => ~"hi"}]
    }.

body_drops_model_adds_version(_Config) ->
    Body = gakudan_llm_vertex:vertex_body(req(), #{}),
    ?assertEqual(error, maps:find(model, Body)),
    ?assertEqual(~"vertex-2023-10-16", maps:get(anthropic_version, Body)).

body_keeps_messages_and_system(_Config) ->
    Body = gakudan_llm_vertex:vertex_body(req(), #{}),
    ?assertMatch([#{role := user}], maps:get(messages, Body)),
    ?assert(maps:is_key(system, Body)),
    ?assert(maps:is_key(max_tokens, Body)).

endpoint_urls(_Config) ->
    Raw = gakudan_llm_vertex:endpoint(~"proj", ~"europe-west1", ~"claude-x", "rawPredict"),
    ?assertEqual(
        "https://europe-west1-aiplatform.googleapis.com/v1/projects/proj/locations/"
        "europe-west1/publishers/anthropic/models/claude-x:rawPredict",
        Raw
    ),
    Stream = gakudan_llm_vertex:endpoint(~"proj", ~"us-east5", ~"claude-x", "streamRawPredict"),
    ?assert(string:find(Stream, ":streamRawPredict") =/= nomatch).

requires_project(_Config) ->
    ?assertEqual(
        {error, {bad_config, missing_project}},
        gakudan_llm_vertex:complete(req(), #{})
    ).

requires_location(_Config) ->
    ?assertEqual(
        {error, {bad_config, missing_location}},
        gakudan_llm_vertex:complete(req(), #{project => ~"p"})
    ).

requires_token(_Config) ->
    ?assertEqual(
        {error, {bad_config, missing_access_token}},
        gakudan_llm_vertex:complete(req(), #{project => ~"p", location => ~"l"})
    ).
