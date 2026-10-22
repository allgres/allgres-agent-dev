# Canvas

Part of the [documentation index](../README.md). See also:
[Task orchestration](task-orchestration.md) for how `delegate` and
`await_children` move work between agents, and [Security](security.md) for
the dashboard's CSP and authentication.

Canvas is a board for arranging and running the agents the control plane
knows about. Admins open it from the dashboard menu (**Canvas**) or at
`/canvas`. Everything on it is a row in PostgreSQL, and every change on it is
an ordinary `dashboard_rpc` action that writes its own `audit_log` row, so
psql can do anything the board can. The page itself keeps only the current
selection and an undo list.

## What is on the board

- **Agents** are nodes. A node shows the model (`policies.llm_config`), how
  many views, functions, procedures, and HTTP hosts the agent holds, and
  whether it runs a model per task.
- **Lines** mean *may delegate to*: an `agent` permission, exactly what
  `delegate` checks at run time (`agent_has_permission`). Drag from an
  agent's bottom dot to another agent to add one; click a line to remove it.
  The line says where work *can* go, not a fixed route; the delegating agent
  still decides at run time.
- **Groups** are boxes: teams, divisions, or projects (`agent_groups`).
  Groups nest, and each agent sits in at most one (`agent_group_members`).
  A group is how an operator arranges agents, not a security boundary; it
  carries no permissions.
- **System agents** sit in their own frame, joined by their
  `parent_agent_id` lines (solid). That column is their permission and
  prompt inheritance edge, so Canvas never sets it, and their grants and
  prompts are changed only from SQL. Their autonomy level is the one dial
  Canvas offers for them.

Positions are stored in `canvas_positions` when you move or resize
something. A card dropped on a box is pulled fully inside it; one that hangs
over the right or bottom edge makes the box grow. Anything never placed by hand is laid out on load: under the
first agent that may delegate to it, inside its group.

## Working on the board

| To | Do |
|---|---|
| Create an agent | Drag **Agent** from the palette (or click it). Without a provider and model it is saved as an inactive draft, the same rule as the Agents page. |
| Create a group | Drag **Group box**, or Shift+click several agents and press **Group selected**. |
| Move into a group | Drag an agent or a group onto a box. Drag it out to take it out. |
| Give a skill | Drag a function, procedure, or view from the palette onto an agent, or use the agent's **Skills** tab. **HTTP host…** asks for a host name. |
| Let one agent delegate to another | Drag from its bottom dot to the other agent. |
| Talk to an agent | Its **Chat** tab, or the **General** dock for `general`. Same conversation as the dashboard's Chat page (`chat.send`). |
| Give a task | The agent's **History** tab, **Start task**. |
| Change model, prompt, limits | The agent's **Settings** tab (`agents.update`). |
| Reuse a team | Select a group, **Save as configuration**, then drag it from the palette. |
| Tidy the board | **Arrange** lays every agent out under the agent that may delegate to it and sizes boxes to fit, then saves those positions. Undo puts the old ones back. |
| Undo | **Undo** or ⌘/Ctrl+Z. Creating an agent is undone by deactivating it; agents are never deleted from Canvas. Merging and deleting groups and placing a saved configuration ask first instead. |

**Flow** switches the side panel to sessions. Pick one to see which agents
took part (working, done, failed), the hand-offs between them as moving
lines, and a timeline of every task start and finish built from
`sessions.get`. **Replay** steps through it.

## The delegation ceiling

A skill given on the board must already be held by every agent that can
delegate to the receiving agent, directly or through others. Otherwise a lead
could route work through a worker to reach a view, function, procedure, or
host the lead was never granted. When agents above are missing it, Canvas
lists them and offers to grant all of them in the same transaction
(`fn_canvas_grant`). If one of them is a system agent, it refuses.

This is the Canvas grant path's own rule. `permissions.grant` (Agents page,
SQL) is the operator's unrestricted tool and does not apply it.

## A model per task

By default every task runs on its agent's `llm_config`. With **Allow a
model per task** on (`agents.allow_task_model`), **Start task** may name a
provider and model; `fn_canvas_run` stores it on that root task
(`tasks.llm_override`) and `fn_next_step` uses it for that task only. It
beats the agent default and a user's chat preference. A function or
procedure `llm_override` still beats it. Delegated children run on their own
agent's model. The provider must be an enabled chat provider; its endpoint
and key come only from that row.

## Saved configurations

`canvas.templates.save` snapshots one group, everything nested in it, each
agent's prompt, model, limits, autonomy, and skills, and the delegation lines
between those agents, into `canvas_templates.body`. Lines to agents outside
the group are left out. Placing it (`canvas.templates.instantiate`) creates
new agents through `fn_create_agent` (each with its own PostgreSQL role and
audit row), suffixing `_2`, `_3` when a name is taken. Nothing links the copy
back to the configuration.

## RPC actions

All require an admin once any account exists, like the Agents page.

| Action | Function |
|---|---|
| `canvas.state` | Groups, memberships, positions, saved configurations |
| `canvas.layout.save` | `fn_canvas_save_positions` (layout only: no audit row) |
| `canvas.groups.create` / `.update` / `.delete` / `.merge` / `.set_member` | `fn_canvas_*_group`, `fn_canvas_merge_groups`, `fn_canvas_set_group_member` |
| `canvas.delegation.add` / `.remove` | `fn_canvas_add_delegation`, `fn_canvas_remove_delegation` |
| `canvas.grant` | `fn_canvas_grant` (the ceiling) |
| `canvas.templates.save` / `.delete` / `.instantiate` | `fn_canvas_save_template`, `fn_canvas_delete_template`, `fn_canvas_instantiate_template` |
| `canvas.run` | `fn_canvas_run`; same access rule as `run` |
| `agents.set_task_model` | `fn_set_task_model_allowed` |

Everything else Canvas does uses existing actions: `agents.list`,
`agents.create`, `agents.update`, `agents.set_autonomy`, `permissions.revoke`,
`permissions.options`, `providers.available`, `chat.send`, `chat.history`,
`tasks.list`, `sessions.list`, and `sessions.get`.

## Signing in

Canvas calls `/api/v1/rpc` with the same `X-Allgres-Client` header and the
dashboard token and login session from the tab's `sessionStorage`. That is
why the menu opens it in the same tab: a new tab starts with an empty
`sessionStorage` and would ask you to sign in again. A regular user who opens
`/canvas` sees "Admins only". Chat and the model pickers need a signed-in
account.

## Not yet

- A master agent that builds teams on its own. The **General** dock is a
  plain conversation with `general`; it does not create agents or groups.
- Inheriting a model or prompt from the agent above. Inheritance is a
  system-agent concept (`parent_agent_id`) and ordinary agents keep their own
  policy.

## Building

The source is a React and [React Flow](https://reactflow.dev) application
in `web/canvas/`. `npm run build` type-checks it, bundles it into a single
HTML file with every script and stylesheet inline, stamps the
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
