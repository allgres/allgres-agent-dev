# Canvas

Part of the [documentation index](../README.md). See also:
[Task orchestration](task-orchestration.md) for how `delegate` and
`await_children` move work between agents, and [Security](security.md) for
the dashboard's CSP and authentication.

Canvas is a board of every agent the control plane knows about. Admins open
it from the dashboard menu (**Canvas**) or at `/canvas`. Each agent is a
node; the lines between them are the relationships PostgreSQL already
enforces:

- **Parent** (solid): `agents.parent_agent_id`. A child sits below its
  parent.
- **May delegate to** (dashed): an `agent` permission. `delegate` succeeds
  only along these lines (`agent_has_permission(..., 'agent', name)`), so the
  board shows where work *can* go, not a fixed route it *will* take; the
  delegating agent still decides at run time. A parent line that also
  carries a delegation grant is drawn once, labelled `delegates`.

A node shows the agent's model (`policies.llm_config`), autonomy level, how
many views, functions, procedures, and HTTP hosts it has been granted, and
how many agents sit below it. Selecting a node opens its policy limits,
every grant by name, and the system prompt. System agents are laid out in
their own frame, matching the fold on the Agents page; inactive agents are
hidden unless **Inactive** is checked.

## What it reads

Canvas keeps no state of its own. It calls `auth.me` and `agents.list`
through the same `/api/v1/rpc` route the dashboard uses, with the same
`X-Allgres-Client` header and the dashboard token and login session from
the tab's `sessionStorage`. That is why the menu opens it in the same tab: a
new tab starts with an empty `sessionStorage` and would ask you to sign in
again. `agents.list` requires an admin once any account exists, so a
regular user who opens `/canvas` sees "Admins only" and nothing else.

The layout is computed in the browser from `parent_agent_id` every time the
page loads. The board re-reads `agents.list` when the tab becomes visible
again and when you press **Refresh**.

## Not yet

This first slice is read-only on purpose. Nodes cannot be dragged and lines
cannot be drawn, because none of the following exists in the database yet,
and a canvas that changed only browser state would contradict the rule that
PostgreSQL owns durable state:

- Groups and teams, including groups nested inside groups.
- Stored canvas positions.
- Setting `parent_agent_id` or granting agent-to-agent delegation from the
  board. `permissions.grant` exists for operators; letting an agent such as a
  master agent grant permissions needs a ceiling rule first (a child may
  receive only what its parent holds).
- A per-task model override. Today every task runs on its agent's
  `llm_config`.

Edit agents on the Agents page for now; **Edit on Agents page** in the
details panel goes there.

## Building

The source is a small React and [React Flow](https://reactflow.dev)
application in `web/canvas/`. `npm run build` type-checks it, bundles it
into a single HTML file with every script and stylesheet inline, stamps the
`__CSP_NONCE__` placeholder on each inline tag (`scripts/emit.mjs`), and
writes `web/canvas.html`. `src/lib.rs` embeds that file with `include_str!`,
and `/canvas` serves it under the same `script-src 'nonce-…'; style-src
'nonce-…'` policy as `/`.

`web/canvas.html` is committed, so `make`, `make install`, the Docker image,
the CNPG image, and the RPM build never need Node.js. Node is a build-time
tool for this one page, never a runtime dependency. After changing anything
under `web/canvas/src`, rebuild and commit the result:

```bash
make canvas
```

CI's `canvas-bundle` job rebuilds from `package-lock.json` and fails if the
committed file differs.

For quicker iteration, `npm run dev` in `web/canvas/` starts Vite and
proxies `/api` to a running dashboard (`ALLGRES_UI_URL`, default
`http://127.0.0.1:8088`). The Vite page is a different origin with its own
`sessionStorage`, so copy `allgres_session_token` from a signed-in dashboard
tab into it before loading. The proxy rewrites `Origin` only for these
development requests; the served `/canvas` page needs no exception.
