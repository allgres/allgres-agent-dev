# Hermes Agent integration

Hermes Agent can be connected in two different roles; they should not be
confused.

## Use Hermes as an OpenAI-compatible model endpoint

Create an `openai_compat` Provider in **Settings → Overview → LLM providers**,
set Hermes' base URL, and store its API credential there. Select that Provider
as an Agent default or as a personal Agent preference. OAuth is only applicable
when the endpoint actually implements an OAuth authorization-code or device-code
flow; otherwise use its bearer/API token.

## Use a Hermes-hosted MCP tool

Create an API connection for the Hermes MCP HTTP endpoint, store its bearer
credential on that connection, then create an `mcp_call` Function whose fixed
tool name targets the remote tool. Grant the Function (or its Procedure) to the
Agent. Capability discovery can recommend it, but the normal Function permission
and approval path still decides whether it runs.

Allgres negotiates streamable HTTP MCP in the protocol order `initialize`,
`notifications/initialized`, then `tools/call`, and propagates the server's
`Mcp-Session-Id` across that exchange. A server that explicitly reports that
`initialize` is unsupported, or exposes only the older stateless HTTP shape,
falls back to a direct `tools/call`. Transport, JSON-RPC, and tool-level errors
remain distinct audited outcomes. Configure the connection's cost-per-call when
the remote service is billable so Capability evaluation includes remote cost.
