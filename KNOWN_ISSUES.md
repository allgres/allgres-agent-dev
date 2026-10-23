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

Agent names are now unique ignoring case and leading/trailing spaces
(`agents_name_ci_key` on `lower(btrim(name))`); `fn_create_agent` refuses
`FIXER` or ` fixer ` while `fixer` exists. Earlier builds allowed such
pairs, and grants and delegation matched them as one name, which let an
ordinary agent stand in for a system agent. If a database carried over by
dumping and restoring into a new install holds such a pair, installing
stops with `agent names must be unique ignoring case and surrounding
spaces; these agents collide: [...]`, listing each group with the agent
ids. Nothing is renamed or merged automatically. Decide which agent keeps
the name, then rename the others and the `agent` grants that name them:

```sql
UPDATE allgres_private.agents SET name = 'fixer_lookalike'
 WHERE agent_id = '<id of the one to rename>';
UPDATE allgres_private.permissions SET resource_ref = 'fixer_lookalike'
 WHERE resource_type = 'agent' AND resource_ref = 'FIXER';
SELECT allgres_private.ensure_agent_names_unique();  -- creates the index
```

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
