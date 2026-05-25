# 6. MCP client + tool integration

Date: 2026-05-25

## Status

Accepted (v0.3).

## Context

Model Context Protocol (MCP) is the de-facto standard for connecting LLM
agents to external capabilities (tools, resources, prompts). Anthropic
publishes the spec; OpenAI, Google, and most agent frameworks now
implement clients. For gakudan to be a credible production agent
runtime in 2026, it must speak MCP.

The realistic deployment shape for `gakudan` is a long-running BEAM
service running multi-agent workloads against centrally-hosted MCP
servers: GitHub MCP, Linear/Jira MCP, custom company-docs MCP, etc.
The agent host connects over HTTPS, not by spawning local processes.
The stdio transport that dominates Claude Code / local-dev use is the
exception, not the rule, in this profile.

Tool integration also needs work. Today `gakudan_tool` is a
single-module, zero-state callback. MCP-discovered tools are not
known at compile time and need per-instance context (which MCP client
to call, which tool name on that client). The current behaviour
forces dynamic module compilation or some other ugly workaround.

## Decision

### Transports

`gakudan` v0.3 ships **Streamable HTTP** transport only. JSON-RPC 2.0
messages POSTed to a single endpoint URL; responses returned in the
HTTP body. Optional SSE upgrade for server-pushed notifications is
not used in v0.3 (no notifications consumed by the library yet).

**stdio** transport is deferred. It can land in v0.3.x or v0.4 without
breaking the public API; `gakudan_mcp_client` config grows a
`transport => stdio | http` key but stays the same module otherwise.
Rationale: production deployments run MCP servers as independent
HTTPS services for isolation, scaling, and lifecycle reasons.
stdio is local-dev / Claude-Code-style usage.

### Client API

A new `gakudan_mcp_client` gen_server, one long-lived process per
MCP endpoint. Started by the host application's supervision tree
under a registered name:

```erlang
{ok, _Pid} = gakudan_mcp_client:start_link(#{
    name => company_github_mcp,
    transport => http,
    base_url => ~"https://mcp.internal/github",
    auth => {bearer, AuthToken}
}).
```

Public ops:

```erlang
list_tools(NameOrPid)          -> {ok, [tool_spec()]} | {error, term()}.
get_tool(NameOrPid, ToolName)  -> {ok, tool_spec()} | {error, not_found | term()}.
call_tool(NameOrPid, ToolName, Input :: map()) ->
    {ok, gakudan_tool:output()} | {error, term()}.
stop(NameOrPid) -> ok.
```

The client performs the MCP `initialize` handshake on `start_link/1`,
caches the server's tool list, and refreshes it on demand. Tool calls
issue a `tools/call` JSON-RPC request and translate the response back
into a `gakudan_tool:output()` (text content concatenated).

Auth is `{bearer, binary()}` in v0.3. OAuth 2.1 (which the MCP spec
mandates for HTTP transports) is deferred. Internal deployments use
bearer tokens; OAuth lands when there's a real consumer.

### `gakudan_tool` extension

Two optional callbacks are added so tools can carry per-instance
state:

```erlang
-callback spec() -> spec().
-callback spec(Opts :: map()) -> spec().
-callback run(Input :: map()) -> result().
-callback run(Input :: map(), Opts :: map()) -> result().
-optional_callbacks([spec/1, run/2]).
```

`gakudan_agent:tools/0` is widened to return
`[module() | {module(), Opts :: map()}]`. Existing agents that return
plain modules keep working byte-for-byte.

The turn worker resolves each entry into a `{Spec, RunFun}` pair
once per turn (so `Mod:spec(Opts)` is called once, not once per LLM
iteration). Dispatch to `RunFun(Input)` is uniform regardless of
whether the tool is in-process or MCP-backed.

### `gakudan_mcp_tool`

A single module implements `gakudan_tool` for any MCP-discovered tool:

```erlang
%% in an agent module
tools() ->
    [
        %% local Erlang tool
        my_local_tool,
        %% MCP tool from a configured client
        {gakudan_mcp_tool, #{client => company_github_mcp, name => ~"search_repos"}},
        {gakudan_mcp_tool, #{client => company_github_mcp, name => ~"read_file"}}
    ].
```

`gakudan_mcp_tool:spec(Opts)` calls `gakudan_mcp_client:get_tool/2`
to fetch the live JSON schema. `gakudan_mcp_tool:run(Input, Opts)`
calls `gakudan_mcp_client:call_tool/3`.

Convenience helper:

```erlang
gakudan_mcp_client:as_tools(ClientName) -> [{gakudan_mcp_tool, Opts}].
```

Returns all of the client's discovered tools, ready to splice into
`agent:tools/0`.

### Sync semantics

MCP `tools/call` is a blocking HTTP request in the turn worker
process. No new behaviour, no async dispatch. Long-running MCP tools
will block the turn until reply or timeout. A separate
`gakudan_tool_async` behaviour for deferred completion is deferred to
v0.4 if a real consumer needs it. The current synchronous model
matches in-process tools and keeps the turn worker simple.

Timeouts: per-tool `timeout_ms` in opts (default 30s). Beyond that the
HTTP request is cancelled and `{error, timeout}` propagates back to
the agent as a normal tool-error.

### Telemetry

MCP calls inherit the existing tool-call telemetry events
(`[gakudan, tool, run, start | stop | exception]` from ADR 0001). The
tool name in metadata is the MCP tool name. No new event names are
added for MCP itself; downstream consumers can subscribe by name if
they want per-server tracking.

### Stability

The `gakudan_mcp_client` public API, the `gakudan_tool` extension
(spec/1, run/2, the widened agents tools list), and the
`gakudan_mcp_tool` opts shape are stable from v0.3 onward and follow
semver.

The internal JSON-RPC framing and the MCP protocol version handshake
are not public API. They track the upstream MCP spec.

## Consequences

**Positive.**

- Drops gakudan into the standard agent ecosystem. Any MCP server
  (GitHub, Linear, Jira, filesystem, custom company servers) is
  reachable from an agent's `tools/0` list with one config line.
- Tool integration is uniform: in-process Erlang tools, MCP HTTP
  tools, and (future) stdio MCP tools all dispatch through the same
  `{Spec, RunFun}` pair. The turn worker doesn't know the difference.
- The `gakudan_tool` extension is backwards-compatible. Existing
  agents and their tool modules keep working.
- The per-endpoint client gen_server scales naturally: multiple
  gakudan runs share one HTTP connection (and one tool-list cache)
  per MCP server. No per-call connection setup.

**Negative.**

- One new mandatory transitive dep: nothing yet, `httpc` ships with
  OTP. (If a real-world auth need pushes us past bearer tokens, we
  pick up gun or hackney then.)
- Tool latency now includes a round-trip to an external HTTPS service.
  Tools that called local Erlang code in microseconds now take tens
  to hundreds of milliseconds for the same call. This is inherent to
  MCP, not a gakudan issue, but worth flagging for cost-sensitive
  paths.
- Synchronous tool calls block the turn worker. A slow MCP server
  (think a vector-DB-backed search server with embedding compute)
  freezes the turn until reply. v0.4 may add async.
- Tool schemas are dynamic. An MCP server can add, remove, or rename
  tools at any time. Agents that hard-code MCP tool names will break
  when the server changes; we document this as a known foot-gun and
  defer a "tool schema version" pin to a future ADR.
- stdio is not in this PR. Local-dev / Claude-Code-style users have
  to wait for the follow-up.