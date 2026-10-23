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
