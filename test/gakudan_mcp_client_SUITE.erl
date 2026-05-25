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
