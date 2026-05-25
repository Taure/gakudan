-module(gakudan_mcp_client).
-moduledoc """
Model Context Protocol client. One gen_server per remote MCP server
endpoint. Speaks the Streamable HTTP transport: JSON-RPC 2.0 POSTed
to a single URL, replies returned in the HTTP body.

Performs the MCP `initialize` handshake on `start_link/1`, caches the
server's tool list, and exposes `list_tools/1`, `get_tool/2`,
`call_tool/3`. Tools are surfaced as `gakudan_tool:ref()` values via
`as_tools/1` so they splice directly into an agent's `tools/0` list.

See [ADR 0006](docs/adr/0006-mcp-client.md).
""".

-behaviour(gen_server).

-export([start_link/1, list_tools/1, get_tool/2, call_tool/3, as_tools/1, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([config/0, auth/0, tool_spec/0]).

-type config() :: #{
    name => atom(),
    transport => http,
    base_url := binary(),
    auth => auth(),
    timeout_ms => non_neg_integer(),
    protocol_version => binary()
}.

-type auth() :: none | {bearer, binary()}.

-type tool_spec() :: gakudan_tool:spec().

-define(DEFAULT_TIMEOUT, 30_000).
-define(DEFAULT_PROTOCOL, ~"2025-06-18").

-record(state, {
    name :: atom() | undefined,
    base_url :: binary(),
    auth :: auth(),
    timeout :: non_neg_integer(),
    protocol :: binary(),
    next_id = 1 :: pos_integer(),
    server_info :: undefined | map(),
    tools = #{} :: #{binary() => tool_spec()}
}).

-doc """
Start an MCP client. Registers the process under `name` (atom) if
given, else returns the pid only. Performs the `initialize` handshake
and caches the server's tool list before returning.
""".
-spec start_link(config()) -> {ok, pid()} | {error, term()}.
start_link(#{base_url := _} = Config) ->
    case maps:get(name, Config, undefined) of
        undefined -> gen_server:start_link(?MODULE, Config, []);
        Name when is_atom(Name) -> gen_server:start_link({local, Name}, ?MODULE, Config, [])
    end.

-doc "Return the cached tool list. The cache is populated at start_link.".
-spec list_tools(atom() | pid()) -> {ok, [tool_spec()]} | {error, term()}.
list_tools(Ref) ->
    gen_server:call(Ref, list_tools, infinity).

-doc "Look up a single tool spec by name.".
-spec get_tool(atom() | pid(), binary()) -> {ok, tool_spec()} | {error, not_found}.
get_tool(Ref, Name) when is_binary(Name) ->
    gen_server:call(Ref, {get_tool, Name}, infinity).

-doc "Invoke a tool on the server. Synchronous; blocks until reply or timeout.".
-spec call_tool(atom() | pid(), binary(), map()) -> gakudan_tool:output().
call_tool(Ref, Name, Input) when is_binary(Name), is_map(Input) ->
    gen_server:call(Ref, {call_tool, Name, Input}, infinity).

-doc """
Return the list of tools as `gakudan_tool:ref()` entries ready to splice
into an agent's `tools/0`. Each entry is `{gakudan_mcp_tool, Opts}`
where `Opts` carries the client name and tool name.
""".
-spec as_tools(atom() | pid()) -> {ok, [gakudan_tool:ref()]} | {error, term()}.
as_tools(Ref) ->
    case list_tools(Ref) of
        {ok, Specs} ->
            {ok, [
                {gakudan_mcp_tool, #{client => Ref, name => maps:get(name, S)}}
             || S <- Specs
            ]};
        Err ->
            Err
    end.

-spec stop(atom() | pid()) -> ok.
stop(Ref) ->
    gen_server:stop(Ref).

init(Config) ->
    State = #state{
        name = maps:get(name, Config, undefined),
        base_url = maps:get(base_url, Config),
        auth = maps:get(auth, Config, none),
        timeout = maps:get(timeout_ms, Config, ?DEFAULT_TIMEOUT),
        protocol = maps:get(protocol_version, Config, ?DEFAULT_PROTOCOL)
    },
    ok = ensure_inets(),
    case handshake(State) of
        {ok, State1} ->
            case refresh_tools(State1) of
                {ok, State2} -> {ok, State2};
                {error, Reason} -> {stop, {tools_refresh_failed, Reason}}
            end;
        {error, Reason} ->
            {stop, {handshake_failed, Reason}}
    end.

handle_call(list_tools, _From, #state{tools = Tools} = State) ->
    {reply, {ok, maps:values(Tools)}, State};
handle_call({get_tool, Name}, _From, #state{tools = Tools} = State) ->
    case maps:find(Name, Tools) of
        {ok, Spec} -> {reply, {ok, Spec}, State};
        error -> {reply, {error, not_found}, State}
    end;
handle_call({call_tool, Name, Input}, _From, State) ->
    {Reply, State1} = do_call_tool(Name, Input, State),
    {reply, Reply, State1};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info(_Msg, State) -> {noreply, State}.

%% --- protocol helpers ---

handshake(State) ->
    Params = #{
        protocolVersion => State#state.protocol,
        capabilities => #{},
        clientInfo => #{name => ~"gakudan", version => ~"0.3"}
    },
    case json_rpc_call(~"initialize", Params, State) of
        {ok, Result, State1} ->
            {ok, State1#state{server_info = Result}};
        {error, _} = Err ->
            Err
    end.

refresh_tools(State) ->
    case json_rpc_call(~"tools/list", #{}, State) of
        {ok, Result, State1} ->
            Tools = parse_tools(maps:get(~"tools", Result, [])),
            {ok, State1#state{tools = Tools}};
        {error, _} = Err ->
            Err
    end.

parse_tools(ToolsJson) ->
    maps:from_list([
        {Name, #{
            name => Name,
            description => maps:get(~"description", T, ~""),
            input_schema => maps:get(~"inputSchema", T, #{})
        }}
     || T <- ToolsJson,
        Name <- [maps:get(~"name", T)],
        is_binary(Name)
    ]).

do_call_tool(Name, Input, State) ->
    Params = #{name => Name, arguments => Input},
    case json_rpc_call(~"tools/call", Params, State) of
        {ok, Result, State1} ->
            {tool_result_from_mcp(Result), State1};
        {error, Reason} ->
            {{error, Reason}, State}
    end.

tool_result_from_mcp(Result) ->
    Content = maps:get(~"content", Result, []),
    IsError = maps:get(~"isError", Result, false),
    Text = collect_text_blocks(Content),
    case IsError of
        true -> {error, Text};
        false -> {ok, Text}
    end.

collect_text_blocks(Blocks) ->
    Texts = [
        T
     || B <- Blocks,
        is_map(B),
        maps:get(~"type", B, undefined) =:= ~"text",
        T <- [maps:get(~"text", B, ~"")]
    ],
    iolist_to_binary(lists:join(~"\n", Texts)).

%% --- JSON-RPC framing over HTTP ---

json_rpc_call(Method, Params, State) ->
    Id = State#state.next_id,
    State1 = State#state{next_id = Id + 1},
    Body = #{
        jsonrpc => ~"2.0",
        id => Id,
        method => Method,
        params => Params
    },
    case http_post(State1, Body) of
        {ok, ResponseJson} ->
            interpret_response(ResponseJson, State1);
        {error, _} = Err ->
            Err
    end.

interpret_response(Json, State) when is_map(Json) ->
    case maps:find(~"error", Json) of
        {ok, ErrObj} ->
            {error, {rpc_error, mcp_error_code(ErrObj), mcp_error_message(ErrObj)}};
        error ->
            case maps:find(~"result", Json) of
                {ok, Result} -> {ok, Result, State};
                error -> {error, {rpc_invalid, Json}}
            end
    end;
interpret_response(Json, _State) ->
    {error, {rpc_invalid, Json}}.

mcp_error_code(#{~"code" := C}) -> C;
mcp_error_code(_) -> 0.

mcp_error_message(#{~"message" := M}) -> M;
mcp_error_message(_) -> ~"".

http_post(State, BodyMap) ->
    Url = binary_to_list(State#state.base_url),
    Headers = headers(State#state.auth),
    Body = iolist_to_binary(json:encode(BodyMap)),
    Request = {Url, Headers, "application/json", Body},
    case
        httpc:request(
            post,
            Request,
            [{timeout, State#state.timeout}],
            [{body_format, binary}]
        )
    of
        {ok, {{_, Code, _}, _Hdrs, RespBody}} when Code >= 200, Code < 300 ->
            decode_body(RespBody);
        {ok, {{_, Code, _}, _Hdrs, RespBody}} ->
            {error, {http_error, Code, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

decode_body(<<>>) ->
    {error, empty_response};
decode_body(Body) ->
    try
        {ok, json:decode(Body)}
    catch
        Class:Reason -> {error, {decode_failed, Class, Reason}}
    end.

headers(none) ->
    [{"accept", "application/json"}];
headers({bearer, Token}) when is_binary(Token) ->
    [
        {"accept", "application/json"},
        {"authorization", binary_to_list(<<"Bearer ", Token/binary>>)}
    ].

ensure_inets() ->
    case inets:start() of
        ok -> ok;
        {error, {already_started, _}} -> ok
    end,
    case ssl:start() of
        ok -> ok;
        {error, {already_started, _}} -> ok
    end.
