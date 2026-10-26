# MCP servers

Use an MCP (Model Context Protocol) server to give agents abilities PostgreSQL cannot provide: research, equipment control, power monitoring, and so on. The server runs outside PostgreSQL. Allgres keeps the connection, the list of tools, how risky each tool is, who may use it, and every call.

Open **Connections → MCP servers** (admin).

## Connect a server

1. Enter a name and the server's address. Add a key if it needs one (sent as `Authorization: Bearer` or `x-api-key`). Tick "on this machine or a private network" only for a server you run yourself.
2. **Connect and look for tools.** The runtime worker asks the server for its tools. The server shows *connected*, *needs a login or key*, or *cannot be reached*, with the server's own error underneath.
3. For each tool, choose what it can do:
   - **Reads only**: approval is not needed by default (you may still ask a person).
   - **Changes data** or **Moves equipment**: a person always approves each call. This cannot be turned off.
4. **Register**. The tool becomes a function and a procedure with the same name. Give an agent that procedure from the Canvas or the Agents page, as you would any other ability.

A tool cannot be registered until you have chosen its level. The page shows a suggestion based on the tool's name and any hints the server sent, but a server's own description of itself is never trusted: the suggestion is only a starting point for your decision.

## When a server changes

**Check again** asks the server for its tools again. If a registered tool's description or inputs changed, its function is switched off and marked *changed* until you click **Approve change**. If the server stops listing a tool, its function is switched off too. This stops a server from quietly changing what an approved tool does.

## Sign in with OAuth

Choose **Sign in with OAuth** when you connect a server that asks you to log in, leave the key empty, then press **Sign in** on the server.

1. Allgres asks the server how it signs people in (the protected resource metadata, then the authorization server's metadata). It needs an authorization server that supports PKCE with S256.
2. It gets a client id: the one you typed, else a Client ID Metadata Document (Allgres serves it at `/oauth/client.json`, and this works only when you reach Allgres over https and the authorization server supports it), else Dynamic Client Registration. If none is possible the page asks for a client id.
3. Your browser goes to the authorization server and comes back to `/oauth/callback`. Allgres checks the one-time `state` and the `iss` the server returns, swaps the code for a token (sending the PKCE verifier and the `resource`), then looks for tools.
4. The token is stored encrypted like every other secret. Allgres renews it a few minutes before it runs out. If the server refuses a renewal, the server shows *needs a login or key* and tools stop until you sign in again. **Sign out** deletes the tokens.

The scopes asked for are the ones the server lists. Sign in from an https address, or from `localhost`; Allgres will not use any other return address.

## Local (stdio) servers

Allgres does not start programs. A server that speaks over stdin and stdout runs outside PostgreSQL behind an HTTP relay (for example a container that exposes the server over Streamable HTTP). Paste the relay's address here and tick the private-network box.

## Protocol support

Allgres sends the 2025 handshake (`initialize`, then the tool request with the session id) first. If a server answers that it has no such method, or rejects it, Allgres sends the request without a handshake, with the protocol version and client identity in `_meta` and the `Mcp-Method` / `Mcp-Name` headers that the 2026-07-28 revision asks for. Replies may be JSON or an event stream.

## What is stored

`api_connections` (kind `mcp`, with `health`), `mcp_tools` (tools, the suggestion, the level a person chose, approval, status, and the registered function and procedure), `mcp_probes` (the discovery queue), `mcp_oauth_config`, `mcp_oauth_flows`, `mcp_oauth_tokens`, `mcp_oauth_jobs` (sign-in), `mcp_risk_rules` (the name patterns behind a suggestion; edit them with SQL). Dashboard actions: `mcp.servers`, `mcp.connect`, `mcp.discover`, `mcp.tools`, `mcp.tool_risk`, `mcp.tool_register`, `mcp.oauth_start`, `mcp.oauth_forget`, and `oauth.callback` (the browser's return, authorized by its one-time state). The design is in [stage3-design.md](stage3-design.md).
