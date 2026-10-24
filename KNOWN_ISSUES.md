# Known limitations

Allgres `0.1.0-alpha.3` is a public alpha. Use it for evaluation and
development, not as the only copy of production data.

## Upgrade compatibility

The alpha does not provide extension upgrade scripts. Install it into a new
database. Until the first stable release, schema and API compatibility may
change between alpha versions.

### Cluster roles renamed to `allgres_operator`, `allgres_worker`, `allgres_sandbox`

Earlier builds created cluster-wide roles named plain `operator`, `worker`,
and `sandbox`, which can collide with roles a cluster already has. They are
now `allgres_operator`, `allgres_worker`, and `allgres_sandbox`. PostgreSQL
roles belong to the whole cluster, so `DROP EXTENSION` never removed the old
ones and installing this build into a new database leaves them in place.
Pick one:

- **Keep a single set (no older Allgres database left in this cluster).**
  Before `CREATE EXTENSION allgres` with this build, rename them. Grants and
  per-agent role memberships follow the role, not its name:
  ```sql
  ALTER ROLE operator RENAME TO allgres_operator;
  ALTER ROLE worker   RENAME TO allgres_worker;
  ALTER ROLE sandbox  RENAME TO allgres_sandbox;
  ```
  A database still running an older build would then fail to assume its
  roles (its functions name the old ones), so reinstall it too.
- **An older Allgres database stays in the cluster.** Leave the old roles;
  this build creates its own. Drop the old ones after the last older
  database is gone (`DROP OWNED BY operator, worker, sandbox;` in each
  database, then `DROP ROLE operator, worker, sandbox;`).

If a login used `operator` or `worker` (for example `psql -U operator`),
switch it to the new name.

### Agent names that differ only in case or surrounding spaces

This build makes agent names unique ignoring case and leading/trailing
spaces: a unique index `agents_name_ci_key` on `lower(btrim(name))`, and
`fn_create_agent` refuses `FIXER` or ` fixer ` while `fixer` exists.
Earlier builds allowed such pairs, and grants and delegation matched them
as one name, which let an ordinary agent stand in for a system agent.

**Existing installs do not get the new rule.** The extension version is
still `0.1.0-alpha.3` and there is no upgrade script, so installing the new
build over an existing database (new binaries, `ALTER EXTENSION allgres
UPDATE`) applies nothing: the index and the `fn_create_agent` check are
missing and case-variant names can still be created. Only a new
`CREATE EXTENSION` gets them. Bringing them to existing installs needs a
version bump with an upgrade script (the missing upgrade path is tracked
separately, review audit #10).

**Dump and restore into a new install fails on such pairs** with a raw
`duplicate key value violates unique constraint "agents_name_ci_key"`
while `pg_restore` loads `allgres_private.agents`. The table is loaded by
one `COPY`, so the error aborts all of it: `agents` is restored empty, not
just missing the later row of each pair, and every table that references
agents (permissions, sessions, tasks, and others) then fails on foreign
keys. Nothing is renamed or merged automatically. Before
dumping, run this on the existing database:

```sql
SELECT lower(btrim(name)) AS normalized_name,
       array_agg(format('%L', name) ORDER BY created_at) AS names,
       array_agg(agent_id ORDER BY created_at) AS agent_ids,
       bool_or(is_system) AS includes_system_agent
  FROM allgres_private.agents
 GROUP BY lower(btrim(name))
HAVING count(*) > 1;
```

No rows means nothing to do. For each row, decide which agent keeps the
name (keep a system agent's name as is), then rename the others and the
`agent` grants that name them, and run the query again until it returns no
rows:

```sql
BEGIN;
UPDATE allgres_private.agents SET name = 'fixer_lookalike'
 WHERE agent_id = '<id of the one to rename>';
UPDATE allgres_private.permissions SET resource_ref = 'fixer_lookalike'
 WHERE resource_type = 'agent' AND resource_ref = 'FIXER';  -- its old spelling, exactly
COMMIT;
```

On a database created by this build, `SELECT
allgres_private.ensure_agent_names_unique();` performs the same check: it
lists every colliding group with agent ids (error 23505) and, when there
are none, creates `agents_name_ci_key` if it is missing.

### `http_host` grants stored with spaces or capitals

This build stores `http_host` grants lower-cased and trimmed on every grant
path, and `fn_revoke_permission` matches ignoring case and surrounding spaces.
Rows written before this stay as they were, and nothing is rewritten
automatically. How they behave depends on the spelling:

- Surrounding spaces (for example, `' api.example.com '`): invalid at run
  time. The host check compares the normalized host, so such a row never
  matches and the grant is silently ineffective.
  `allgres_private.canvas_delegation_gaps` also reports it as a gap, so Canvas
  refuses a delegation line over an agent that holds it.
- Capitals only (for example, `'API.Example.com'`): still match at run time,
  because the permission check compares case-insensitively, and are not
  reported as gaps. Cleanup is still recommended so every host has a single
  normalized row.

Check for rows that need cleanup:

```sql
SELECT agent_id, format('%L', resource_ref) AS stored, lower(btrim(resource_ref)) AS normalized
  FROM allgres_private.permissions
 WHERE resource_type = 'http_host' AND resource_ref <> lower(btrim(resource_ref));
```

Run this one-time cleanup on an existing database. The first `DELETE` drops
an un-normalized row when an already-normalized row exists for the same agent
and host. The second `DELETE` drops duplicate un-normalized spellings of the
same host, keeping one row. Then the remaining rows are normalized:

```sql
BEGIN;
DELETE FROM allgres_private.permissions p
 WHERE p.resource_type = 'http_host'
   AND p.resource_ref <> lower(btrim(p.resource_ref))
   AND EXISTS (SELECT 1 FROM allgres_private.permissions q
                WHERE q.agent_id = p.agent_id AND q.resource_type = 'http_host'
                  AND q.resource_ref = lower(btrim(p.resource_ref)));
DELETE FROM allgres_private.permissions p
 USING allgres_private.permissions q
 WHERE p.resource_type = 'http_host' AND q.resource_type = 'http_host'
   AND p.agent_id = q.agent_id
   AND p.resource_ref <> lower(btrim(p.resource_ref))
   AND q.resource_ref <> lower(btrim(q.resource_ref))
   AND lower(btrim(p.resource_ref)) = lower(btrim(q.resource_ref))
   AND p.permission_id > q.permission_id;
UPDATE allgres_private.permissions
   SET resource_ref = lower(btrim(resource_ref))
 WHERE resource_type = 'http_host' AND resource_ref <> lower(btrim(resource_ref));
COMMIT;
```

The check query above returns no rows afterwards.

### Functions named like a builtin

This build refuses Function names `http_get`, `http_request`, `mcp_call`,
and `plpgsql`, ignoring case and surrounding spaces. The create API,
dashboard RPC, agent actions (including proposal creation and approval),
and a table trigger enforce the rule. The update API never changes names;
the trigger also guards direct renames. Unrelated updates to legacy rows
remain possible. This build's runtime ignores reserved-name Function rows,
so they cannot shadow a builtin.

**Existing installs get nothing on upgrade.** The version is still
`0.1.0-alpha.3` and there is no upgrade script. Replacing binaries and
running `ALTER EXTENSION allgres UPDATE` applies none of these SQL changes,
including the runtime guards. Only a new `CREATE EXTENSION` gets them;
existing installs need a version bump and upgrade script to acquire them.

Before dumping an existing install, detect collisions:

```sql
SELECT function_id, name, handler, is_active
FROM allgres_private.functions
WHERE lower(btrim(name)) IN ('http_get','http_request','mcp_call','plpgsql');
```

Rename and deactivate these rows, choosing unused names (and shortening
names if needed to respect the 63-character limit):

```sql
UPDATE allgres_private.functions
SET name = name || '_renamed', is_active = false
WHERE lower(btrim(name)) IN ('http_get','http_request','mcp_call','plpgsql');
```

Revisit permissions rows with `resource_type = 'function'` that named those
Functions: those names now mean the builtin. Review their procedure
bindings too before reactivating a renamed Function.

`functions` is an extension config-dumped table (`pg_extension_config_dump`
in `sql/seed_data.sql`). Restoring a dump with a reserved-name row into a
new install fails when the trigger rejects that row's `COPY`, aborting the
table's load. Clean up before dumping; nothing is automatically renamed.

### Seed rows in `pg_dump` (`is_seed`)

New installs mark the extension's nine seeded tables with `is_seed` and dump
only unmarked rows. This avoids the duplicate-key failures that previously
aborted `COPY` for functions, providers, procedures, and the sandbox
allowlist; user grants and references to seed agents, the `seoul-weather`
procedure, and the `seoul_weather` function now restore, because those seed
rows have fixed IDs. The documented two-pass
restore was manually verified with no errors, duplicate keys, or dangling
references. A single-pass restore still has the documented policy collision.

Every other `allgres_private` table holding user state (accounts, agent
assignments and chat-session links, preferences, messenger messages, fix
proposals, call records, function history, user capabilities, canvas
groups/positions/templates) is also registered; `fn_selftest()` check
`dump_coverage_all_user_state_tables` fails when a table is neither
registered nor on the short not-dumped list in
[Backup and restore](docs/backup-and-restore.md). Login tokens
(`web_sessions`) are deliberately not dumped, so users log in again after a
restore. Edits to seed rows are still lost on a logical restore.

**Existing installs get nothing on upgrade.** The version is still
`0.1.0-alpha.3` and there is no upgrade script. They retain the old dump
filters, random seed IDs, and no marker. Check for the marker with:

```sql
SELECT count(*) FROM information_schema.columns WHERE table_schema = 'allgres_private' AND column_name = 'is_seed';
```

`9` means it is present. Until an upgrade script exists, use a new
install for this behavior or retain physical backups when seed-row edits must
be preserved. The upgrade must add the nine columns, create and run
`allgres_private.mark_seed_rows()` (`mark_seed_rows(true)` is a dry run that
reports unmarked seed rows), replace all nine dump filters with `WHERE NOT is_seed`,
and remap the seeded agent, procedure, and function IDs (or document that
old dump references will not match a fresh install).

## Deployment coverage

- PostgreSQL 16, 17, and 18 are covered by CI.
- The bundled Docker image uses PostgreSQL 17.
- The CNPG example requires PostgreSQL 18 and Kubernetes Image Volume support.
  It is an example manifest, not a production-ready Helm chart.
- A Fedora 43 / PostgreSQL 18 RPM is published with the alpha release. DEB
  packages and a general-purpose Kubernetes deployment chart are not available.

## Security posture

- The zero-configuration Docker setup is intentionally limited to loopback.
  Set a dashboard token, secret key, and strong PostgreSQL password before
  exposing it beyond a local machine.
- TLS termination and network policy are deployment responsibilities.
- `pgcrypto` is required to encrypt provider credentials at rest.
- The operator audit log records application-level actor information; retain
  PostgreSQL and platform audit logs for security investigations.

## Optional capabilities

- `pgvector` accelerates semantic search but is not required.
- Helm charts and a native package repository are planned after the alpha.

Please report defects through GitHub Issues. Report vulnerabilities using the
private process in [SECURITY.md](SECURITY.md).
