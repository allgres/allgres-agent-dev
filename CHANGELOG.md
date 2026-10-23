# Changelog

All notable changes will be documented here.

## Unreleased

- **Breaking:** the cluster-wide roles `operator`, `worker`, and `sandbox` are now `allgres_operator`, `allgres_worker`, and `allgres_sandbox`, so they no longer collide with roles a cluster may already have. Roles are cluster-wide and survive `DROP EXTENSION`; see KNOWN_ISSUES.md, "Cluster roles renamed", for renaming or dropping the old ones.
- Building from source needs rustc 1.96 or newer (pgrx 0.19.2's `rust-version`). README and the source guide say so, `Cargo.toml` declares `rust-version = "1.96"`, and `make` stops early with an update hint instead of failing inside `cargo install cargo-pgrx`.
- `tests/cleanup.sql` retires what `tests/*.sql` leave behind (fixture agents renamed to `selftest_*` and deactivated, their sessions hidden, grants and test-only functions removed) and fails if any is still visible; `scripts/run_sql_tests.sh`, CI, and `scripts/smoke.sh` run it last. `e2e_mock.sql` now uses its own `e2e_mock_runner` agent instead of repointing the seeded `analyst` at the mock model, and `smoke.sql` no longer overwrites the `openai` provider's key.
- Dashboard checks the `Host` header against an allowlist (`localhost`, the bind host, IP literals, `ALLGRES_ALLOWED_HOSTS`) and answers `421` otherwise, closing DNS rebinding against a tokenless install. On by default when no token is set.
- Canvas delegation lines are now checked on the server: a line into or out of a system agent is refused (D2), and a line is refused when the receiving agent, or anything below it, holds a view, function, procedure, or HTTP host that the sending agent or anything above it lacks (D1, the same delegation ceiling `fn_canvas_grant` already applied). Template placement goes through the same check.
- Canvas (`/canvas`, admin menu → Canvas): a board for building the organization. Add agents and nested teams from one **+ Add** menu (or start from an example team), drop one agent's card onto another to put it under that agent (a delegation line, an `agent` grant), give abilities named in plain words under a delegation ceiling, chat with any agent or General, start tasks (optionally on a per-task model), save a group as a reusable configuration, and see who actually handed work to whom in the Flow view. English and Korean; system agents hidden until asked for. New tables `agent_groups`, `agent_group_members`, `canvas_positions`, and `canvas_templates`, columns `agents.allow_task_model` and `tasks.llm_override`, and 15 `canvas.*`/`agents.set_task_model` RPC actions (sql/canvas.sql). The React source lives in `web/canvas`; the built page is committed as `web/canvas.html`, so building the extension still needs no Node.js.

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
