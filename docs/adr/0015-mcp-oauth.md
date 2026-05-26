# 15. OAuth 2.1 for the MCP client

Date: 2026-05-27

## Status

Accepted (v0.5).

## Context

`gakudan_mcp_client` (ADR 0006) authenticates to a remote MCP server with a
static bearer token or nothing. The MCP authorization spec is built on OAuth
2.1, and enterprise MCP servers increasingly sit behind an OAuth gateway that
rejects a static token. gakudan needs to obtain and refresh tokens itself.

The MCP authorization spec is written mostly for *interactive* clients: an
authorization-code + PKCE flow, with authorization-server metadata discovery
(RFC 8414) and dynamic client registration (RFC 7591), all of which assume a
user-agent that can follow a redirect and a human who can consent. gakudan is
none of that. The MCP client is a **headless server-side gen_server** in a
backend orchestration runtime; there is no browser and no interactive user to
delegate to.

The OAuth 2.1 grant that fits a headless, machine-to-machine client is
**client credentials**: the client authenticates as itself to a token
endpoint and receives an access token. That is the grant a backend service
uses to call another service, and it is the one to implement here.

## Decision

### A `{oauth2, Config}` auth mode (client-credentials)

```erlang
auth => {oauth2, #{
    token_url     => ~"https://auth.example.com/oauth/token",
    client_id     => ~"...",
    client_secret => ~"...",
    scope         => ~"mcp.read mcp.tools"   %% optional
}}
```

The client `POST`s `grant_type=client_credentials` (form-encoded, with
`client_id`/`client_secret`/optional `scope`) to `token_url`, reads
`access_token` and `expires_in`, and uses the token as a `Bearer` header on
every MCP request - exactly the header the existing `{bearer, _}` mode emits,
so the request path is unchanged.

### Token caching and refresh

The token is cached in the gen_server state with an absolute expiry
(`now + expires_in - skew`, 30s skew). Before each MCP request the client
checks the cache and fetches a fresh token only when it is missing or expired.
As a backstop, a `401` response with `oauth2` auth invalidates the cache,
fetches a new token, and retries the request **once**; a second `401` is
returned as an error. This covers a token revoked before its stated expiry.

### Non-goals

- **Authorization-code + PKCE.** Interactive, user-delegated; no place in a
  headless runtime.
- **Auth-server metadata discovery / dynamic client registration.** The
  consumer configures `token_url` and credentials directly. Discovery can be
  added later if a consumer needs it; it is not required to authenticate.
- **Refresh tokens.** Client-credentials does not issue them (the client just
  re-runs the grant); so there is nothing to store.

## Consequences

**Positive.**

- gakudan can talk to OAuth-gated MCP servers without a static long-lived
  token, obtaining and refreshing short-lived tokens itself.
- The token becomes a `Bearer` header, so the change is localised to auth
  resolution; the JSON-RPC-over-HTTP path is untouched.
- The cache means one token fetch amortises across many calls; the 401-retry
  makes early revocation self-healing.

**Negative.**

- Only the client-credentials grant is supported. A server that demands
  user-delegated auth-code is out of scope (and a poor match for a backend
  client anyway).
- Token fetch is a synchronous extra HTTP round-trip on the first call (and
  after expiry), on the path of the MCP request that triggered it.
- The client secret lives in the client config / state; it is never logged,
  but it is held in memory like any credential.
