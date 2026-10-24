# Tests

Part of the [documentation index](../README.md). See also:
[Evaluation-gated self-improvement](self-improvement.md) for the one named
scenario deliberately not automated here.

```bash
cargo pgrx test --features pg17   # Rust unit tests (request parsing, auth, parse-tree reader)
./scripts/smoke.sh                # container smoke, end-to-end, and security checks
psql -c "SELECT allgres_public.fn_selftest()"
./scripts/bootstrap.sh            # install completion: a real agent task runs to 'completed'
./scripts/run_sql_tests.sh        # tests/*.sql against PG* env, then tests/cleanup.sql
./scripts/run_dump_restore_test.sh  # pg_dump + two-pass restore on throwaway clusters
scripts/with_nodns.sh CMD...      # run CMD where .invalid lookups fail (see below)
```

The `tests/*.sql` files need the background workers (and
`ALLGRES_ENABLE_MOCK=1`) and create real fixture agents (`e2e_*`,
`smoke_role_agent_*`, `execution_safety_worker`), sessions, and test-only
functions. `tests/cleanup.sql` retires all of them: it deletes their grants,
assignments, and test-only functions, renames the agents to `selftest_*`,
deactivates them, and marks their sessions as selftest, so they disappear
from every listing (logs are append-only, so rows are retired, not
deleted). It then fails if any of them is still visible. `run_sql_tests.sh`,
CI, and `scripts/smoke.sh` run it last; run it yourself after running any
of the files by hand. The suite no longer changes the seeded `analyst`
agent or the `openai` provider's key.

`run_dump_restore_test.sh` needs no running cluster: it initdb's a source
and a restore cluster under one temporary directory (removed on exit),
listening only on a Unix socket there, with the web/mock worker on
`ALLGRES_DR_HTTP_ADDR` (default `127.0.0.1:18088`, which must be free). The
source gets user rows in every user-state table (`tests/dump_restore_fixture.sql`),
a web login and a chat turn answered by the mock, and a user procedure call
harvested by the worker. After `pg_dump -Fc` and the two-pass restore it
checks: no restore errors, equal row counts per table, no orphan foreign keys
and the fixture rows (`tests/dump_restore_verify.sql`), `fn_selftest()`
with no failures. It then points the worker at the restored database: a
user procedure call is harvested again (`tests/dump_restore_exec.sql`), and
the same user logs in over the web RPC and continues the same chat session,
with the reply harvested from the mock. Set `PG_BIN` to the PostgreSQL bin
directory when `pg_config` on `PATH` is not the target install.

### Tests that need a failing DNS lookup

`tests/fixed_url_procedure_e2e.sql`, `tests/legacy_reserved_name_row.sql`,
and `tests/dump_restore_exec.sql` prove that the runtime worker really
executed a call by sending it to an RFC 2606 `.invalid` host. The worker
then records `outbound_calls.error_kind = 'dns'`. That value comes from the
Rust executor's own classification of the failure, not from the error text,
which depends on the OS resolver, and only the runtime worker can record it.
Each of these files first includes `tests/require_failing_dns.sql`. That
file resolves a random `.invalid` name through the executor's resolution
path (`allgres.resolve_host_addresses`: getaddrinfo in a backend of the
worker's postmaster). If the name resolves, it stops with:

    environment unsuitable: resolver answers .invalid names (got 198.18.0.1 for ...);
    run the cluster under scripts/with_nodns.sh (see docs/testing.md)

Some sandboxes run a resolver that answers every name. There the worker's
private-network guard would refuse the call (`error_kind =
'blocked_address'`), and the test would fail for a reason unrelated to the
code. A real resolver, CI runners included, fails the lookup, so the check
passes silently there and CI needs no setup.

`allgres.resolve_host_addresses` waits at most 5 seconds for the resolver
and checks for interrupts every 50 ms while it waits, so `statement_timeout`
and `pg_cancel_backend` stop it at once. A resolver that does not answer in
time is reported as an error (SQLSTATE 58000, "did not finish within 5 s"),
not as a failed lookup, so the pre-flight does not pass on it. Only its
owner (`allgres_owner`) and superusers can execute it; there is no grant.

In such a sandbox, start the PostgreSQL server under `scripts/with_nodns.sh`.
Clients need nothing:

```bash
scripts/with_nodns.sh pg_ctl -D "$PGDATA" -l "$PGDATA/server.log" start
./scripts/run_sql_tests.sh
scripts/with_nodns.sh ./scripts/run_dump_restore_test.sh   # it starts its own clusters
```

`with_nodns.sh` runs its command in a private mount namespace. In that
namespace `/etc/nsswitch.conf` is a bind-mounted copy whose `hosts:` line is
`files`: `/etc/hosts` (localhost) still resolves, and every other name fails
with glibc's CI wording. The host's `/etc/nsswitch.conf` is never written.
Only processes started under the command see the change, including a
postmaster that outlives the script. Stop that postmaster with `pg_ctl stop`
as usual from any shell.

The script needs no privileges where unprivileged user namespaces are
allowed. It uses a user namespace only to make the bind mount, then a nested
one maps you back to your own uid/gid, because PostgreSQL refuses to run as
root. Without user namespaces it falls back to `sudo -n unshare -m` plus
`setpriv`. Set `ALLGRES_NODNS_MODE=sudo` or `ALLGRES_NODNS_MODE=userns` to
pick a mode. It also needs util-linux 2.38 or newer and glibc. See
`scripts/with_nodns.sh --help`.

`fn_selftest` is a live diagnostic, not a fresh-install-only check: every
fixture it creates is either uniquely named and hard-deleted before it
returns, or left behind deactivated and hidden from every operator-facing
listing by `goal LIKE 'selftest%'` (see `selftest_fixtures_hidden_not_deleted`
in `sql/selftest.sql`) — the same convention real accounts, real
agents, real policy history, and real queued work all already rely on not
being disturbed by. Run it against a database that has been in production
for months exactly the same way as right after `CREATE EXTENSION allgres`;
nothing in it assumes an empty install, an exact row count anywhere in the
schema, or that no admin account exists yet (confirmed live: a full
`fn_selftest()` pass with a real admin account, and real agent/session/task
history already in the database, both taken before every commit that
touches any of `sql/control_plane.sql`, `sql/operator_agents_and_policies.sql`,
`sql/operator_runtime_and_integrations.sql`,
`sql/operator_accounts_and_chat.sql`, `sql/seed_data.sql`,
`sql/selftest.sql`, or `sql/grants_and_facade.sql`).

`scripts/fault_injection_drill.sh` is a separate, runnable drill (bare-metal,
like `scripts/backup_drill.sh`) that sends a real `SIGKILL` to the real
`allgres runtime` worker while a real sandboxed-SQL call and a real LLM/HTTP
call are genuinely in flight, and proves the whole claim → crash → recovery
→ `fn_watchdog` reclaim → automatic retry → completion cycle happens on its
own — not a `fn_selftest` case, since that would need a SQL function to kill
its own OS process. It kills and restarts the entire instance it is pointed
at, on purpose; never run it against anything serving real traffic — a
GitHub-hosted CI runner is exactly the disposable instance this warning
allows, so `fault-injection-drill` in `.github/workflows/ci.yml` runs it on
every push, covering roadmap item 9's "재시작, 재시도" (restart, retry)
scenarios the same way `docker-smoke` covers "계정 생성 후 사용, 설정 변경,
모델 교체" (account-creation-then-use, config change, model swap) via
`scripts/bootstrap.sh`. See KNOWN_ISSUES.md, item 26.
