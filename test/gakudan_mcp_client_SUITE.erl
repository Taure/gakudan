-module(gakudan_mcp_client_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    start_link_completes_handshake/1,
    list_tools_returns_cached_specs/1,
    get_tool_returns_named_spec/1,
    get_tool_missing_returns_not_found/1,
    call_tool_round_trip/1,
    call_tool_isError_maps_to_error_tuple/1,
    rpc_error_propagates/1,
    bearer_auth_header_is_sent/1,
    oauth2_fetches_token_and_sends_bearer/1,
    oauth2_caches_token_across_calls/1,
    oauth2_missing_access_token_fails_start/1,
    oauth2_401_invalidates_cache_and_retries_once/1,
    oauth2_second_401_is_terminal/1,
    as_tools_returns_gakudan_mcp_tool_refs/1,
    tool_resolution_through_gakudan_mcp_tool/1
]).

all() ->
    [
        start_link_completes_handshake,
        list_tools_returns_cached_specs,
        get_tool_returns_named_spec,
        get_tool_missing_returns_not_found,
        call_tool_round_trip,
        call_tool_isError_maps_to_error_tuple,
        rpc_error_propagates,
        bearer_auth_header_is_sent,
        oauth2_fetches_token_and_sends_bearer,
        oauth2_caches_token_across_calls,
        oauth2_missing_access_token_fails_start,
        oauth2_401_invalidates_cache_and_retries_once,
        oauth2_second_401_is_terminal,
        as_tools_returns_gakudan_mcp_tool_refs,
        tool_resolution_through_gakudan_mcp_tool
    ].

init_per_testcase(_Name, Config) ->
    application:ensure_all_started(inets),
    application:ensure_all_started(ssl),
    Config.

end_per_testcase(_Name, _Config) ->
    ok.

start_link_completes_handshake(_Config) ->
    {ok, Server} = mcp_stub_server:start(default_handler()),
    {ok, Pid} = start_client(Server),
    {ok, Tools} = gakudan_mcp_client:list_tools(Pid),
    ?assertEqual(2, length(Tools)),
    Calls = mcp_stub_server:calls(Server),
    Methods = [maps:get(~"method", maps:get(body, C)) || C <- Calls],
    ?assertEqual([~"initialize", ~"tools/list"], Methods),
    gakudan_mcp_client:stop(Pid),
    mcp_stub_server:stop(Server).

list_tools_returns_cached_specs(_Config) ->
    {ok, Server} = mcp_stub_server:start(default_handler()),
    {ok, Pid} = start_client(Server),
    {ok, Tools} = gakudan_mcp_client:list_tools(Pid),
    Names = lists:sort([maps:get(name, T) || T <- Tools]),
    ?assertEqual([~"echo", ~"search"], Names),
    gakudan_mcp_client:stop(Pid),
    mcp_stub_server:stop(Server).

get_tool_returns_named_spec(_Config) ->
    {ok, Server} = mcp_stub_server:start(default_handler()),
    {ok, Pid} = start_client(Server),
    {ok, Echo} = gakudan_mcp_client:get_tool(Pid, ~"echo"),
    ?assertEqual(~"echo", maps:get(name, Echo)),
    ?assertMatch(#{description := _}, Echo),
    gakudan_mcp_client:stop(Pid),
    mcp_stub_server:stop(Server).

get_tool_missing_returns_not_found(_Config) ->
    {ok, Server} = mcp_stub_server:start(default_handler()),
    {ok, Pid} = start_client(Server),
    ?assertEqual({error, not_found}, gakudan_mcp_client:get_tool(Pid, ~"nope")),
    gakudan_mcp_client:stop(Pid),
    mcp_stub_server:stop(Server).

call_tool_round_trip(_Config) ->
    {ok, Server} = mcp_stub_server:start(default_handler()),
    {ok, Pid} = start_client(Server),
    {ok, Output} = gakudan_mcp_client:call_tool(Pid, ~"echo", #{msg => ~"hi"}),
    ?assertEqual(~"echo: hi", Output),
    gakudan_mcp_client:stop(Pid),
    mcp_stub_server:stop(Server).

call_tool_isError_maps_to_error_tuple(_Config) ->
    Handler = fun
        (#{~"method" := ~"initialize"}) ->
            rpc_result(1, #{protocolVersion => ~"2025-06-18"});
        (#{~"method" := ~"tools/list"}) ->
            rpc_result(2, #{tools => [echo_tool_spec()]});
        (#{~"method" := ~"tools/call"}) ->
            rpc_result(3, #{
                content => [#{type => ~"text", text => ~"upstream failed"}],
                isError => true
            })
    end,
    {ok, Server} = mcp_stub_server:start(Handler),
    {ok, Pid} = start_client(Server),
    Result = gakudan_mcp_client:call_tool(Pid, ~"echo", #{}),
    ?assertEqual({error, ~"upstream failed"}, Result),
    gakudan_mcp_client:stop(Pid),
    mcp_stub_server:stop(Server).

rpc_error_propagates(_Config) ->
    Handler = fun
        (#{~"method" := ~"initialize"}) ->
            rpc_result(1, #{protocolVersion => ~"2025-06-18"});
        (#{~"method" := ~"tools/list"}) ->
            rpc_result(2, #{tools => [echo_tool_spec()]});
        (#{~"method" := ~"tools/call"}) ->
            #{
                jsonrpc => ~"2.0",
                id => 3,
                error => #{code => -32601, message => ~"unknown method"}
            }
    end,
    {ok, Server} = mcp_stub_server:start(Handler),
    {ok, Pid} = start_client(Server),
    Result = gakudan_mcp_client:call_tool(Pid, ~"echo", #{}),
    ?assertMatch({error, {rpc_error, -32601, _}}, Result),
    gakudan_mcp_client:stop(Pid),
    mcp_stub_server:stop(Server).

bearer_auth_header_is_sent(_Config) ->
    {ok, Server} = mcp_stub_server:start(default_handler()),
    {ok, Pid} = gakudan_mcp_client:start_link(#{
        base_url => stub_url(Server),
        auth => {bearer, ~"sk-test-token"}
    }),
    Calls = mcp_stub_server:calls(Server),
    %% inspect the first request headers
    [First | _] = Calls,
    Headers = maps:get(headers, First),
    ?assertEqual(
        ~"Bearer sk-test-token",
        proplists:get_value("authorization", Headers)
    ),
    gakudan_mcp_client:stop(Pid),
    mcp_stub_server:stop(Server).

oauth2_fetches_token_and_sends_bearer(_Config) ->
    {ok, Server} = mcp_stub_server:start(oauth_handler(~"oauth-tok-1")),
    Url = stub_url(Server),
    {ok, Pid} = gakudan_mcp_client:start_link(#{
        base_url => Url,
        auth =>
            {oauth2, #{
                token_url => Url,
                client_id => ~"cid",
                client_secret => ~"sec",
                scope => ~"mcp.tools"
            }}
    }),
    Calls = mcp_stub_server:calls(Server),
    MCPCalls = [C || C <- Calls, maps:is_key(~"method", maps:get(body, C))],
    [First | _] = MCPCalls,
    ?assertEqual(
        ~"Bearer oauth-tok-1",
        proplists:get_value("authorization", maps:get(headers, First))
    ),
    gakudan_mcp_client:stop(Pid),
    mcp_stub_server:stop(Server).

oauth2_caches_token_across_calls(_Config) ->
    {ok, Server} = mcp_stub_server:start(oauth_handler(~"oauth-tok-2")),
    Url = stub_url(Server),
    {ok, Pid} = gakudan_mcp_client:start_link(#{
        base_url => Url,
        auth => {oauth2, #{token_url => Url, client_id => ~"cid", client_secret => ~"sec"}}
    }),
    %% handshake makes two MCP calls (initialize + tools/list) but the token
    %% is fetched once and reused.
    Calls = mcp_stub_server:calls(Server),
    TokenCalls = [C || C <- Calls, not maps:is_key(~"method", maps:get(body, C))],
    ?assertEqual(1, length(TokenCalls)),
    gakudan_mcp_client:stop(Pid),
    mcp_stub_server:stop(Server).

oauth2_missing_access_token_fails_start(_Config) ->
    %% start_link links the failing process to us; trap so its exit signal
    %% does not take the test process down.
    process_flag(trap_exit, true),
    Handler = fun
        (#{~"method" := _} = Body) -> (default_handler())(Body);
        (_) -> #{~"error" => ~"invalid_client"}
    end,
    {ok, Server} = mcp_stub_server:start(Handler),
    Url = stub_url(Server),
    Result = gakudan_mcp_client:start_link(#{
        base_url => Url,
        auth => {oauth2, #{token_url => Url, client_id => ~"x", client_secret => ~"y"}}
    }),
    ?assertMatch({error, {handshake_failed, {oauth_token_failed, no_access_token}}}, Result),
    mcp_stub_server:stop(Server).

oauth2_401_invalidates_cache_and_retries_once(_Config) ->
    %% The first MCP call after the token fetch gets a 401; the client must
    %% refetch the token and retry once, then succeed.
    Counter = counters:new(1, []),
    Handler = fun
        (#{~"method" := _} = Body) ->
            case counters:get(Counter, 1) of
                0 ->
                    counters:add(Counter, 1, 1),
                    {401, ~"unauthorized"};
                _ ->
                    (default_handler())(Body)
            end;
        (_) ->
            #{~"access_token" => ~"tok", ~"expires_in" => 3600}
    end,
    {ok, Server} = mcp_stub_server:start(Handler),
    Url = stub_url(Server),
    {ok, Pid} = gakudan_mcp_client:start_link(#{
        base_url => Url,
        auth => {oauth2, #{token_url => Url, client_id => ~"c", client_secret => ~"s"}}
    }),
    Calls = mcp_stub_server:calls(Server),
    TokenCalls = [C || C <- Calls, not maps:is_key(~"method", maps:get(body, C))],
    %% initial fetch + one refetch after the 401.
    ?assert(length(TokenCalls) >= 2),
    gakudan_mcp_client:stop(Pid),
    mcp_stub_server:stop(Server).

oauth2_second_401_is_terminal(_Config) ->
    %% Every MCP call 401s: retry-once must give up cleanly, never loop.
    process_flag(trap_exit, true),
    Handler = fun
        (#{~"method" := _}) -> {401, ~"nope"};
        (_) -> #{~"access_token" => ~"tok", ~"expires_in" => 3600}
    end,
    {ok, Server} = mcp_stub_server:start(Handler),
    Url = stub_url(Server),
    Result = gakudan_mcp_client:start_link(#{
        base_url => Url,
        auth => {oauth2, #{token_url => Url, client_id => ~"c", client_secret => ~"s"}}
    }),
    ?assertMatch({error, {handshake_failed, {http_error, 401, _}}}, Result),
    mcp_stub_server:stop(Server).

as_tools_returns_gakudan_mcp_tool_refs(_Config) ->
    {ok, Server} = mcp_stub_server:start(default_handler()),
    {ok, Pid} = start_client(Server),
    {ok, Refs} = gakudan_mcp_client:as_tools(Pid),
    ?assertEqual(2, length(Refs)),
    lists:foreach(
        fun
            ({gakudan_mcp_tool, #{client := C, name := N}}) ->
                ?assertEqual(Pid, C),
                ?assert(is_binary(N));
            (Other) ->
                ct:fail({unexpected_ref, Other})
        end,
        Refs
    ),
    gakudan_mcp_client:stop(Pid),
    mcp_stub_server:stop(Server).

tool_resolution_through_gakudan_mcp_tool(_Config) ->
    {ok, Server} = mcp_stub_server:start(default_handler()),
    {ok, Pid} = start_client(Server),
    Ref = {gakudan_mcp_tool, #{client => Pid, name => ~"echo"}},
    Resolved = gakudan_tool:resolve_one(Ref),
    Spec = maps:get(spec, Resolved),
    ?assertEqual(~"echo", maps:get(name, Spec)),
    RunFun = maps:get(run, Resolved),
    {ok, Output} = RunFun(#{msg => ~"world"}),
    ?assertEqual(~"echo: world", Output),
    gakudan_mcp_client:stop(Pid),
    mcp_stub_server:stop(Server).

%% --- helpers ---

start_client(Server) ->
    gakudan_mcp_client:start_link(#{base_url => stub_url(Server)}).

stub_url(#{port := Port}) ->
    iolist_to_binary(io_lib:format("http://127.0.0.1:~p/", [Port])).

default_handler() ->
    fun
        (#{~"method" := ~"initialize", ~"id" := Id}) ->
            rpc_result(Id, #{
                protocolVersion => ~"2025-06-18",
                capabilities => #{},
                serverInfo => #{name => ~"stub", version => ~"1.0"}
            });
        (#{~"method" := ~"tools/list", ~"id" := Id}) ->
            rpc_result(Id, #{tools => [echo_tool_spec(), search_tool_spec()]});
        (#{~"method" := ~"tools/call", ~"id" := Id, ~"params" := Params}) ->
            Name = maps:get(~"name", Params),
            Args = maps:get(~"arguments", Params, #{}),
            Text = handle_tool_call(Name, Args),
            rpc_result(Id, #{content => [#{type => ~"text", text => Text}]})
    end.

%% Like default_handler, but a non-JSON-RPC body (the form-encoded token
%% request) gets the OAuth token response.
oauth_handler(Token) ->
    Default = default_handler(),
    fun
        (#{~"method" := _} = Body) ->
            Default(Body);
        (_) ->
            #{~"access_token" => Token, ~"expires_in" => 3600, ~"token_type" => ~"Bearer"}
    end.

handle_tool_call(~"echo", #{~"msg" := Msg}) ->
    iolist_to_binary([~"echo: ", Msg]);
handle_tool_call(~"echo", _) ->
    ~"echo: <empty>";
handle_tool_call(~"search", #{~"query" := Q}) ->
    iolist_to_binary([~"search results for: ", Q]);
handle_tool_call(_, _) ->
    ~"unsupported".

echo_tool_spec() ->
    #{
        name => ~"echo",
        description => ~"Echo a message.",
        inputSchema => #{
            type => ~"object",
            properties => #{msg => #{type => ~"string"}},
            required => [~"msg"]
        }
    }.

search_tool_spec() ->
    #{
        name => ~"search",
        description => ~"Search.",
        inputSchema => #{
            type => ~"object",
            properties => #{query => #{type => ~"string"}},
            required => [~"query"]
        }
    }.

rpc_result(Id, Result) ->
    #{jsonrpc => ~"2.0", id => Id, result => Result}.
