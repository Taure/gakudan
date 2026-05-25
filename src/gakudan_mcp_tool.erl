-module(gakudan_mcp_tool).
-moduledoc """
Single `gakudan_tool` adapter that wraps any MCP-discovered tool. Used
in `agent:tools/0` as `{gakudan_mcp_tool, Opts}` where `Opts` carries
the MCP client reference and the tool name on that server.

```erlang
tools() ->
    [
        {gakudan_mcp_tool, #{client => company_github_mcp, name => ~"search_repos"}},
        {gakudan_mcp_tool, #{client => linear_mcp, name => ~"create_ticket"}}
    ].
```

`spec/1` consults the client's cached tool list. `run/2` issues the
tool call. See [ADR 0006](docs/adr/0006-mcp-client.md).
""".

-behaviour(gakudan_tool).

-export([spec/1, run/2]).

-spec spec(map()) -> gakudan_tool:spec().
spec(#{client := Client, name := Name}) ->
    case gakudan_mcp_client:get_tool(Client, Name) of
        {ok, Spec} -> Spec;
        {error, Reason} -> error({mcp_tool_unknown, Client, Name, Reason})
    end.

-spec run(map(), map()) -> gakudan_tool:output().
run(Input, #{client := Client, name := Name}) ->
    gakudan_mcp_client:call_tool(Client, Name, Input).
