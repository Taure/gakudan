-module(gakudan_mcp_client).
-moduledoc """
Model Context Protocol client. One gen_server per remote MCP server
endpoint. Speaks the Streamable HTTP transport: JSON-RPC 2.0 POSTed
to a single URL, replies returned in the HTTP body.

Performs the MCP `initialize` handshake on `start_link/1`, caches the
server's tool list, and exposes `list_tools/1`, `get_tool/2`,
`call_tool/3`. Tools are surfaced as `gakudan_tool:ref()` values via
`as_tools/1` so they splice directly into an agent's `tools/0` list.

Auth is `none`, a static `{bearer, Token}`, or `{oauth2, Config}` - the
OAuth 2.1 client-credentials grant for OAuth-gated servers, with the token
fetched, cached, and refreshed automatically. See
[ADR 0006](docs/adr/0006-mcp-client.md) and
[ADR 0015](docs/adr/0015-mcp-oauth.md).
""".

-behaviour(gen_server).

-export([start_link/1, list_tools/1, get_tool/2, call_tool/3, as_tools/1, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([config/0, auth/0, oauth_config/0, tool_spec/0]).

-type config() :: #{
    name => atom(),
    transport => http,
    base_url := binary(),
    auth => auth(),
    timeout_ms => non_neg_integer(),
    protocol_version => binary()
}.

-type auth() :: none | {bearer, binary()} | {oauth2, oauth_config()}.

-type oauth_config() :: #{
    token_url := binary(),
    client_id := binary(),
    client_secret := binary(),
    scope => binary()
}.

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
    tools = #{} :: #{binary() => tool_spec()},
    token_cache :: undefined | #{access_token := binary(), expires_at := integer()}
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
        {ok, ResponseJson, State2} ->
            interpret_response(ResponseJson, State2);
        {error, Reason, _State2} ->
            {error, Reason}
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
    http_post(State, BodyMap, true).

http_post(State, BodyMap, RetryOn401) ->
    case resolve_auth(State) of
        {ok, AuthHeaders, State1} ->
            case do_post(State1, BodyMap, AuthHeaders) of
                {ok, {{_, 401, _}, _Hdrs, RespBody}} ->
                    case {RetryOn401, State1#state.auth} of
                        {true, {oauth2, _}} ->
                            %% Token may have been revoked early: refetch once.
                            http_post(State1#state{token_cache = undefined}, BodyMap, false);
                        _ ->
                            {error, {http_error, 401, RespBody}, State1}
                    end;
                {ok, {{_, Code, _}, _Hdrs, RespBody}} when Code >= 200, Code < 300 ->
                    case decode_body(RespBody) of
                        {ok, Json} -> {ok, Json, State1};
                        {error, Reason} -> {error, Reason, State1}
                    end;
                {ok, {{_, Code, _}, _Hdrs, RespBody}} ->
                    {error, {http_error, Code, RespBody}, State1};
                {error, Reason} ->
                    {error, Reason, State1}
            end;
        {error, Reason, State1} ->
            {error, Reason, State1}
    end.

do_post(State, BodyMap, AuthHeaders) ->
    Url = binary_to_list(State#state.base_url),
    Headers = [{"accept", "application/json"} | AuthHeaders],
    Body = iolist_to_binary(json:encode(BodyMap)),
    Request = {Url, Headers, "application/json", Body},
    httpc:request(post, Request, [{timeout, State#state.timeout}], [{body_format, binary}]).

decode_body(<<>>) ->
    {error, empty_response};
decode_body(Body) ->
    try
        {ok, json:decode(Body)}
    catch
        Class:Reason -> {error, {decode_failed, Class, Reason}}
    end.

resolve_auth(#state{auth = none} = State) ->
    {ok, [], State};
resolve_auth(#state{auth = {bearer, Token}} = State) when is_binary(Token) ->
    {ok, [bearer_header(Token)], State};
resolve_auth(#state{auth = {oauth2, Cfg}} = State) ->
    case ensure_token(Cfg, State) of
        {ok, Token, State1} -> {ok, [bearer_header(Token)], State1};
        {error, Reason} -> {error, {oauth_token_failed, Reason}, State}
    end.

bearer_header(Token) ->
    {"authorization", binary_to_list(<<"Bearer ", Token/binary>>)}.

ensure_token(Cfg, State) ->
    Now = erlang:system_time(second),
    case State#state.token_cache of
        #{access_token := Token, expires_at := ExpiresAt} when ExpiresAt > Now ->
            {ok, Token, State};
        _ ->
            fetch_and_cache(Cfg, State)
    end.

fetch_and_cache(Cfg, State) ->
    case fetch_token(Cfg, State#state.timeout) of
        {ok, Token, ExpiresIn} ->
            %% Clamp the safety skew so a short-lived token still caches for a
            %% positive window rather than being born expired.
            Skew = min(30, ExpiresIn div 2),
            ExpiresAt = erlang:system_time(second) + ExpiresIn - Skew,
            Cache = #{access_token => Token, expires_at => ExpiresAt},
            {ok, Token, State#state{token_cache = Cache}};
        {error, _} = Err ->
            Err
    end.

fetch_token(#{token_url := Url, client_id := Id, client_secret := Secret} = Cfg, Timeout) ->
    Params =
        [
            {"grant_type", "client_credentials"},
            {"client_id", binary_to_list(Id)},
            {"client_secret", binary_to_list(Secret)}
        ] ++ scope_param(maps:get(scope, Cfg, undefined)),
    Form = uri_string:compose_query(Params),
    Request =
        {
            binary_to_list(Url),
            [{"accept", "application/json"}],
            "application/x-www-form-urlencoded",
            Form
        },
    case httpc:request(post, Request, [{timeout, Timeout}], [{body_format, binary}]) of
        {ok, {{_, Code, _}, _Hdrs, Body}} when Code >= 200, Code < 300 ->
            parse_token(Body);
        {ok, {{_, Code, _}, _Hdrs, Body}} ->
            {error, {token_http_error, Code, Body}};
        {error, Reason} ->
            {error, Reason}
    end.

scope_param(undefined) -> [];
scope_param(Scope) when is_binary(Scope) -> [{"scope", binary_to_list(Scope)}].

parse_token(Body) ->
    case decode_body(Body) of
        {ok, #{~"access_token" := Token} = Json} when is_binary(Token) ->
            {ok, Token, expires_in(maps:get(~"expires_in", Json, 3600))};
        {ok, _} ->
            {error, no_access_token};
        {error, _} = Err ->
            Err
    end.

%% Some servers omit or mis-type expires_in; fall back to a sane default
%% rather than crash on the arithmetic.
expires_in(N) when is_integer(N), N > 0 -> N;
expires_in(_) -> 3600.

ensure_inets() ->
    case inets:start() of
        ok -> ok;
        {error, {already_started, _}} -> ok
    end,
    case ssl:start() of
        ok -> ok;
        {error, {already_started, _}} -> ok
    end.
