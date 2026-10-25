# Changelog

All notable changes will be documented here.

## Unreleased

- Canvas (`/canvas`, admin menu → Canvas): a board for building the organization. Add agents and nested teams from one **+ Add** menu (or start from an example team), drop one agent's card onto another to put it under that agent (a delegation line, an `agent` grant), give abilities named in plain words under a delegation ceiling, chat with any agent or General, start tasks (optionally on a per-task model), save a group as a reusable configuration, and see who actually handed work to whom in the Flow view. English and Korean; system agents hidden until asked for. New tables `agent_groups`, `agent_group_members`, `canvas_positions`, and `canvas_templates`, columns `agents.allow_task_model` and `tasks.llm_override`, and 15 `canvas.*`/`agents.set_task_model` RPC actions (sql/canvas.sql). The React source lives in `web/canvas`; the built page is committed as `web/canvas.html`, so building the extension still needs no Node.js.

- Decision records (sql/decision_records.sql, docs/decision-records.md). When a person approves or rejects an approval request or a change proposal, Allgres now keeps an append-only record of the situation, the question as asked, and the answer, with a gold label, in the shape Laya's trainer and evaluator read. New tables `decision_points`, `decision_records`, `decision_labels`, and `decision_exports`; `decisions.export` returns `laya-train` / `laya-evals` JSONL with a train/eval split that never shares a situation. Secrets never enter a record. Five new admin RPC actions (`decisions.*`). Nothing is decided by a model; this only keeps what people decided.
- People, roles, and approval routing (sql/org_routing.sql, docs/approvals-and-roles.md). New tables `org_units`, `org_roles`, `org_memberships`, `approval_rules`, and `approval_delegations`; routing and decider columns on `human_approvals` and `change_proposals`; a rule routes an approval or proposal to a role, with escalation to a second role and time-boxed delegation. `approvals.decide` and `proposals.decide` enforce it and record who decided. `approvals.list` and `proposals.list` take `mine`. Eleven new admin RPC actions (`org.*`, `approval_rules.*`, `approval_delegations.*`). With no rule, behavior is unchanged.
- Canvas safety fixes. Drawing a delegation line now obeys the delegation ceiling: it is refused, with the missing grants named, when an agent above the line lacks a view, function, procedure, or HTTP host that the receiving agent (or an agent below it) holds. A system agent can no longer be the receiver of a line. The permissions editor's function picker lists every active registered function, not only `http_get` and `http_request`. A fresh install shows the "Build your first team" guide again (the seeded agents no longer count as a team), now above the seeded cards.

## 0.1.0-alpha.3

- Built-in mock now answers `GET /mock/models` (and `/mock/v1/models`) so Settings → Test connection works against the same endpoint bootstrap uses for a first chat.
- Dashboard onboarding marks step 3 complete after General has finished a turn, not only after a model is saved.
- Provider probe errors prefer a JSON `error` field over the raw response body, so a 404 is `not_found` rather than `{"ok":false,"error":"not_found"}`.
- Creating a regular user assigns the seeded `general` agent so Chat works on first login without an extra Users-page click.
- Dashboard folds `health_monitor` with System agents so the main Agents list is conversation agents, not the seeded maintenance example.

## 0.1.0-alpha.2

- Onboarding checklist, Chat General as a 1:1 conversation, selftest isolation, and first-run draft/project guards.

## 0.1.0-alpha.1

- First public alpha.
- PostgreSQL-native agent control plane with Rust/pgrx runtime and web workers.
- PostgreSQL 16, 17, and 18 support.
- Docker and CloudNativePG extension images for amd64 and arm64.
