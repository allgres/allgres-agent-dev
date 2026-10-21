# Changelog

All notable changes will be documented here.

## Unreleased

- Canvas (`/canvas`, admin menu → Canvas): a board for building the organization. Create agents and nested groups (teams, divisions, projects) by drag and drop, draw delegation lines (`agent` grants), drag skills onto agents under a delegation ceiling, chat with any agent or the General dock, start tasks (optionally on a per-task model), save a group as a reusable configuration, and replay a session's hand-offs in the Flow view. New tables `agent_groups`, `agent_group_members`, `canvas_positions`, and `canvas_templates`, columns `agents.allow_task_model` and `tasks.llm_override`, and 15 `canvas.*`/`agents.set_task_model` RPC actions (sql/canvas.sql). The React source lives in `web/canvas`; the built page is committed as `web/canvas.html`, so building the extension still needs no Node.js.

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
