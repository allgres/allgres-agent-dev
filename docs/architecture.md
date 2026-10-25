# Architecture

Part of the [documentation index](../README.md). See also: [Security
model](security.md), [Configuration](configuration.md).

```text
Browser
  | HTTP + SSE
  v
Allgres web BGWorker (Rust, no SPI, one thread per connection)
  | unix socket, 0600 inside a 0700 directory under PGDATA
  v
Allgres runtime BGWorker
  |  SPI thread ......... short transactions only (pump, dashboard RPC)
  |  HTTP thread pool ... blocking LLM / function calls, never touches Postgres
  v
PL/pgSQL control plane
  +--> agent state, policy, queue, retries, audit log
  +--> outbound request construction and validation
```

The Rust layer owns I/O and process lifecycle only. Agent state, policies,
queues, retries, audit logs, and dashboard operations remain in PostgreSQL.

Outbound HTTP runs on pool threads, so the SPI thread stays free for the
dashboard: an in-flight LLM call no longer blocks `/api/v1/*`. All SQL issued
from Rust uses bound parameters; nothing concatenates a value into a statement.

## Everything the dashboard does, `psql` can do too

`allgres.dashboard_rpc(jsonb)` is the *only* thing the web layer calls into
PostgreSQL for — the browser and `/api/v1/*` are one client of it, not a
privileged one. Every mutation it exposes is a thin, gate-then-delegate
wrapper around a plain PL/pgSQL function (`fn_create_agent`,
`fn_set_policy`, `fn_create_provider`, `fn_grant_permission`,
`fn_set_user_active`, ...) that takes typed arguments, not a jsonb request
body — the same function an operator can call directly from `psql` with no
HTTP, no dashboard, and no JSON in sight, exactly the way this project's
own development creates its very first admin account
(`psql -c "SELECT fn_create_user(...)"`, see [Docker install, in
detail](deployment/docker.md)). `dashboard_rpc`'s own job is strictly session
resolution, admin gating, and the operator audit log entry — never logic a
direct SQL caller would be missing out on. A handful of mutations
(`users.set_active`/`set_role`, a user's agent assignments) used to be the
exception, with their real `UPDATE`/`INSERT`/`DELETE` written inline in
`dashboard_rpc` itself and reachable only through the jsonb envelope;
`fn_set_user_active`/`fn_set_user_role`/`fn_set_user_assignments`/
`fn_set_user_assignment` closed that gap, each verified live with a plain
`SELECT` and no `dashboard_rpc` call anywhere in the session. Read-only
listings (`agents.list`, `sessions.list`, `overview`, ...) are the one
deliberate exception to "wrapped in a function": they're ad hoc queries
shaped for the API response, and an operator wanting the same data via SQL
can just query the underlying tables directly — that's more SQL-native
than calling a read wrapper, not less.

## Overview: cluster monitoring

Overview also reports PostgreSQL's own version and this database's
`pg_stat_activity` session counts (active/idle/idle-in-transaction), plus
host-level CPU load and memory — the one thing SQL cannot see on its own,
read from `/proc/loadavg`/`/proc/meminfo` by a new native function,
`allgres.native_host_stats()` (Linux-only by design, the same reasoning as
`analyze_sql`'s use of PostgreSQL's own parser: the most direct interface
available, not the most portable one — it degrades to `null` sections
rather than an error if `/proc` is unavailable).

## Navigation, language, and theme

The admin menu is grouped by what you are doing:

| Group | Pages |
|---|---|
| (top) | **Home** |
| **Organization** | **Canvas**, **Agents**, **People** (accounts, roles, units, approval rules, delegation) |
| **Work** | **General**, **Projects**, **Approvals** (Approvals, Proposals, Fixes, and for admins Decisions; open to regular users too, see [System agents](system-agents.md)), **Activity** (Sessions, Tasks, Logs), **Schedules** |
| **Abilities** | **Functions & procedures**, **Memories**, **SQL** |
| **Connections** | **Models & prices**, **APIs** |
| **Settings** | **Access & appearance** (token, your name, SQL allowlist, theme), **Audit log** |

**Home** puts what needs you first: three *Get started* steps until they are
done (a provider that passed its connection test and a model for General; an
agent a person built, not a system or seeded one; a finished task), then
requests waiting for your decision, tasks in progress, and anything that needs
attention. The counters, cluster, and workers are under *System status*.

Regular users see **Work** (General, Projects, Approvals) and **My agents**.
Internal page ids are unchanged, so a browser's saved page still opens. The
pages that used to be one Settings page are the same panels, shown a few at a
time (`SETTINGS_PAGES` in `web/index.html`).

The Access & appearance page has a dark/light theme switch stored in the browser's
`localStorage`. The partial English/한국어 switch was removed: the current
dashboard is English-only rather than presenting a partly translated UI.
The top navigation button is labeled **Home**.
