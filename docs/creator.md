# Building capabilities by conversation

The built-in **creator** agent turns a plain request into something the platform can use. Run it from the Run page (or give it a task from a chat) and describe what you need, for example: "agents should be able to search the web and write up what they find with sources".

## What it decides

It reads its guide, the usage document `creator_guide` (edit it under Functions & procedures; every edit is kept as a version), and works in this order:

1. **Already there?** It searches the capabilities that exist and, if one fits, only says which agent should be given it.
2. **Can the database do it?** Reading and shaping data, rules, arithmetic: it proposes a PL/pgSQL **function**.
3. **A way of working?** Steps to follow, or a chain of abilities that already exist: it proposes a **usage document** (a procedure, versioned).
4. **Must it reach the outside world?** The web, a device, a company system: it writes no code. It names the kind of MCP server to connect and sends you to Connections, MCP servers. Once that is connected, ask it for a usage document on using the tools well.

## What you see before you decide

Everything it proposes waits in **Approvals**. A proposal carries a check:

- the function body's rules (no SECURITY DEFINER, no role change);
- whether PostgreSQL **compiles** it (in a throw-away object, rolled back at once);
- whether a key, password or token looks written into the text.

The check **reads and compiles the code; it does not run it.** A function runs only after approval, under the rights of the agent that calls it. Your approve or reject is kept as a decision record like any other proposal.

## After approval

The approved function or document exists but nobody has it yet. Under **Decided**, tick the agents that should have it and press **Give**; they get the matching permission. System agents cannot be given one. A document proposed under a name that exists becomes a new version of it (`procedure_history` keeps the old one).

## Limits

- Only the creator can propose a usage document. Any agent may still propose a function, as before.
- The creator cannot create an HTTP function or an MCP tool; those are made by a person (Functions page, MCP servers page).
- Capability search needs an embedding model configured; without one the creator decides from the request alone.
- The guide covers the order of choice, how to write each kind, rights, and secrets. Registering a new decision point is only suggested in its reason; a person registers it.
