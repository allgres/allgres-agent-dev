# Canvas

Part of the [documentation index](../README.md). See also:
[Task orchestration](task-orchestration.md) for how `delegate` and
`await_children` move work between agents, and [Security](security.md) for
the dashboard's CSP and authentication.

Canvas is a board for arranging and running the agents the control plane
knows about. [`docs/mockups/agent-canvas.html`](mockups/agent-canvas.html)
is the design mockup it was built from (open it in a browser; it is a
standalone page with example data, not wired to the database). Admins open it from the dashboard menu (**Canvas**) or at
`/canvas`. Everything on it is a row in PostgreSQL, and every change on it is
an ordinary `dashboard_rpc` action that writes its own `audit_log` row, so
psql can do anything the board can. The page itself keeps only the current
selection and an undo list.

## What is on the board

- **Agents** are nodes. A node shows the model (`policies.llm_config`), how
  many views, functions, procedures, and HTTP hosts the agent holds, and
  whether it runs a model per task.
- **Blue dashed arrows, "can delegate to"**, are an `agent` permission,
  exactly what `delegate` checks at run time (`agent_has_permission`). Drag
  from an agent's **+** dot and every agent that can take the line lights up;
  release on one (its card or its dot) to add the line, and click a line to
  remove it. The line says where work *can* go, not a fixed route; the
  delegating agent still decides at run time. System agents cannot be
  delegated to from Canvas.
- **Groups** are boxes: teams, divisions, or projects (`agent_groups`).
  Groups nest, and each agent sits in at most one (`agent_group_members`).
  A group is how an operator arranges agents, not a security boundary; it
  carries no permissions.
- **System agents** sit in their own frame, joined by orange **"inherits"**
  arrows from parent to child (`parent_agent_id`). A card shows "+N
  inherited" for abilities that come down that chain, and the panel's Abilities lists
  them with where each comes from. That column is their permission and
  prompt inheritance edge, so Canvas never sets it, and their grants and
  prompts are changed only from SQL. Their autonomy level is the one dial
  Canvas offers for them.

Positions are stored in `canvas_positions` when you move or resize
something. A card dropped on a box is pulled fully inside it; one that hangs
over the right or bottom edge makes the box grow. Anything never placed by hand is laid out on load: under the
first agent that may delegate to it, inside its group.

## Working on the board

Canvas is built for someone arranging a team, not editing a database: the
board shows only the agents and teams, everything is added from one **+ Add**
button, and abilities are named in plain words ("Read web pages", "Read: My
tasks") with the stored name in a tooltip. It speaks English and Korean
(한/EN in the top bar; the first visit follows the browser language).

| To | Do |
|---|---|
| Add an agent, a team, or a saved team | **+ Add**, then click a row (it lands in the middle, or in the selected team) or drag it to a spot. A new agent without a model is saved turned off, the same rule as the Agents page. |
| Start from something | On an empty board, **Start from an example**, or **+ Add → Example team**: a lead and two members, turned off until they have a model. |
| Put one agent under another | Drag its card onto the other agent's card. The upper agent may now hand it work (the line), it joins the upper agent's team, and it sits just below. One undo reverses all three. |
| Let an agent hand work without moving it | Drag from the **+** under its card to another agent (every agent that can take the line lights up), or use **Hands work to** in its panel. Click a line to remove it. |
| Make a team from agents | Shift+click them, then **Make a team** in the bar that appears. |
| Move into or out of a team | Drag a card or a box onto a box; it is pulled fully inside. Drag it out to take it out, or use **In team** in the panel. |
| Choose a model, turn an agent on | Its panel: **Model** and the on/off switch. A card says **Needs a model** until it has one. |
| Change what it does, its abilities | Its panel: **What it does**, **Abilities**. Limits and the per-task model option sit under **Advanced**. |
| Talk to an agent, give it a task | **Chat** and **Activity** in its panel, or **Ask General** in the corner. Same conversation as the dashboard's Chat page (`chat.send`). |
| Reuse a team | Select its box, **Save as a reusable team**, then add it from **+ Add**. |
| Tidy up | **⋯ → Tidy up layout** lays every agent out under the one that hands it work and sizes boxes to fit. |
| Undo | **↶** or ⌘/Ctrl+Z. Creating an agent is undone by turning it off; agents are never deleted from Canvas. Merging and deleting teams ask first instead. |

**Getting started** in the corner lists the four steps to a first working
team (add an agent, choose its model, put one under another, give the top
one a task), ticked from what is really there; each step is one click away.
Selecting an agent fades everything it does not work with. Keys: **N** new
agent, **T** new team, **F** fit to screen, **?** help, **⌘/Ctrl+Z** undo.

**What it does** edits only the job. A new agent's stored prompt starts with
the reply protocol the runtime needs (reply with one JSON object, the shape
of each action; `ensure_policy`), and Canvas keeps that in front, adding the
job under `# Your job`, rather than letting a plain sentence replace it. A
prompt written whole by hand is shown and saved whole.

System agents are hidden until **⋯ → Show system agents**. **?** in the
corner explains every mark on the board. Right-click a card, a team box, or
an empty spot for the same actions without dragging ("Put under…", turn on
or off, new agent here). Opened in a tab that is not signed in, Canvas asks
for the admin account (or the dashboard token) in place, and the dashboard
in that tab is signed in too.

**Flow** fades the permission lines and draws, in green, every hand-off that
actually happened in the last 500 tasks, with how many times ("handed work
×3"); cards show whether each agent's latest task finished or failed. Pick a
session to see which agents
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
dashboard token and login session from the tab's `sessionStorage`
(`allgres_token`, `allgres_session_token`). A tab with neither asks for them
on the spot and stores them under the same keys the dashboard uses. A
regular user sees "Admins only". Chat and the model pickers need a signed-in
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
