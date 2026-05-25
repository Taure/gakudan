-module(mcp_stub_server).
-moduledoc false.

%% Minimal HTTP/1.1 stub for MCP client tests. Listens on an ephemeral
%% port, accepts one POST at a time, dispatches the request body
%% (parsed as JSON) through a handler fun, and serves the handler's
%% response back as application/json. Connection: close after each
%% request.

-export([start/1, start/2, stop/1, port/1, calls/1, set_handler/2]).
-export([init/3]).

-record(state, {
    listen_socket :: gen_tcp:socket(),
    handler :: fun((map()) -> term()),
    calls = [] :: [map()]
}).

-spec start(fun((map()) -> term())) -> {ok, pid()}.
start(Handler) ->
    start(Handler, 0).

-spec start(fun((map()) -> term()), inet:port_number()) -> {ok, pid()}.
start(Handler, Port) ->
    {ok, ListenSocket} = gen_tcp:listen(Port, [
        binary,
        {active, false},
        {reuseaddr, true},
        {packet, http_bin}
    ]),
    {ok, AssignedPort} = inet:port(ListenSocket),
    Pid = spawn_link(?MODULE, init, [self(), ListenSocket, Handler]),
    {ok, #{pid => Pid, port => AssignedPort, socket => ListenSocket}}.

stop(#{pid := Pid, socket := Socket}) ->
    try
        gen_tcp:close(Socket)
    catch
        _:_ -> ok
    end,
    Pid ! shutdown,
    ok.

port(#{port := P}) -> P.

calls(#{pid := Pid}) ->
    Pid ! {calls, self()},
    receive
        {calls, Calls} -> Calls
    after 1000 ->
        []
    end.

set_handler(#{pid := Pid}, Handler) ->
    Pid ! {set_handler, Handler},
    ok.

init(_Parent, ListenSocket, Handler) ->
    State = #state{
        listen_socket = ListenSocket,
        handler = Handler
    },
    loop(State).

loop(State) ->
    case gen_tcp:accept(State#state.listen_socket, 100) of
        {ok, Socket} ->
            State1 = handle_one(Socket, State),
            gen_tcp:close(Socket),
            check_messages(State1);
        {error, timeout} ->
            check_messages(State);
        {error, closed} ->
            ok
    end.

check_messages(State) ->
    receive
        shutdown ->
            ok;
        {calls, From} ->
            From ! {calls, lists:reverse(State#state.calls)},
            loop(State);
        {set_handler, H} ->
            loop(State#state{handler = H})
    after 0 ->
        loop(State)
    end.

handle_one(Socket, State) ->
    case read_request(Socket) of
        {ok, Method, Path, Headers, Body} ->
            BodyJson =
                case Body of
                    <<>> -> #{};
                    _ -> safe_decode(Body)
                end,
            Call = #{
                method => Method,
                path => Path,
                headers => Headers,
                body => BodyJson
            },
            Response = invoke_handler(State#state.handler, BodyJson),
            send_response(Socket, Response),
            State#state{calls = [Call | State#state.calls]};
        {error, _} ->
            State
    end.

safe_decode(B) ->
    try
        json:decode(B)
    catch
        _:_ -> #{}
    end.

invoke_handler(H, Body) ->
    try H(Body) of
        Map when is_map(Map) -> {200, json:encode(Map)};
        {Map, _Hdrs} when is_map(Map) -> {200, json:encode(Map)};
        {Status, IoData} when is_integer(Status) -> {Status, IoData}
    catch
        Class:Reason ->
            {500, iolist_to_binary(io_lib:format("handler error: ~p:~p", [Class, Reason]))}
    end.

read_request(Socket) ->
    inet:setopts(Socket, [{packet, http_bin}, {active, false}]),
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, {http_request, Method, {abs_path, Path}, _Version}} ->
            read_headers(Socket, Method, Path, []);
        {ok, {http_request, Method, Path, _Version}} ->
            read_headers(Socket, Method, Path, []);
        {error, _} = Err ->
            Err
    end.

read_headers(Socket, Method, Path, Acc) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, http_eoh} ->
            ContentLength = content_length(Acc),
            read_body(Socket, Method, Path, Acc, ContentLength);
        {ok, {http_header, _, Field, _, Value}} ->
            FieldStr = header_name(Field),
            ValueStr = to_binary(Value),
            read_headers(Socket, Method, Path, [{FieldStr, ValueStr} | Acc]);
        {error, _} = Err ->
            Err
    end.

header_name(F) when is_atom(F) -> string:lowercase(atom_to_list(F));
header_name(F) when is_binary(F) -> string:lowercase(binary_to_list(F));
header_name(F) when is_list(F) -> string:lowercase(F).

to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_list(V) -> list_to_binary(V).

content_length(Hdrs) ->
    case lists:keyfind("content-length", 1, Hdrs) of
        {_, Val} -> binary_to_integer(Val);
        false -> 0
    end.

read_body(_Socket, Method, Path, Headers, 0) ->
    {ok, atom_to_list(Method), to_binary(Path), Headers, <<>>};
read_body(Socket, Method, Path, Headers, N) ->
    inet:setopts(Socket, [{packet, raw}]),
    case gen_tcp:recv(Socket, N, 5000) of
        {ok, Body} ->
            {ok, atom_to_list(Method), to_binary(Path), Headers, Body};
        {error, _} = Err ->
            Err
    end.

send_response(Socket, {Status, Body}) ->
    Bin = iolist_to_binary(Body),
    StatusLine = io_lib:format("HTTP/1.1 ~p ~s\r\n", [Status, status_text(Status)]),
    Headers = io_lib:format(
        "content-type: application/json\r\ncontent-length: ~p\r\nconnection: close\r\n\r\n",
        [byte_size(Bin)]
    ),
    gen_tcp:send(Socket, [StatusLine, Headers, Bin]).

status_text(200) -> "OK";
status_text(400) -> "Bad Request";
status_text(401) -> "Unauthorized";
status_text(500) -> "Internal Server Error";
status_text(_) -> "OK".
