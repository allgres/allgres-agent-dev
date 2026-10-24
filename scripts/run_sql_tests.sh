#!/usr/bin/env bash
# Run the tests/*.sql suite against the database libpq points at (PGHOST,
# PGPORT, PGUSER, PGDATABASE), with the allgres background workers running,
# then run tests/cleanup.sql -- always, also after a failure -- so the
# fixture agents, sessions, and test-only functions the suite creates do not
# stay in the dashboard.
#
#   ./scripts/run_sql_tests.sh
#   ALLGRES_TEST_HTTP_ADDR=127.0.0.1:18088 ./scripts/run_sql_tests.sh
#
# ALLGRES_TEST_HTTP_ADDR is the web worker's address (ALLGRES_HTTP_ADDR) when
# it is not the default 127.0.0.1:8088; the tests point mock providers at it.
# It needs ALLGRES_ENABLE_MOCK=1 on the server. The suite needs a superuser.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
addr=${ALLGRES_TEST_HTTP_ADDR:-127.0.0.1:8088}
files=(smoke execution_safety execution_safety_worker outbound_error_kind_gate e2e_mock capability_governance capability_search_e2e procedure_binding_e2e fixed_url_procedure_e2e legacy_reserved_name_row schedule_worker_e2e)

# Read the test files through a path relative to the current directory, not
# the absolute "$root/tests". CI runs this script as postgres
# (sudo -u postgres ...) from a checkout under /home/runner, which postgres
# cannot traverse (mode 750): opening /home/runner/.../tests/x.sql fails with
# "Permission denied", while a relative path is resolved from the cwd and
# does not need search permission on its ancestors. realpath -s -m is purely
# lexical, so computing the relative path does not touch those ancestors either.
tests=$(realpath -s -m --relative-to="$PWD" "$root/tests")
dir="$tests"
if [[ "$addr" != "127.0.0.1:8088" ]]; then
  dir=$(mktemp -d)
  trap 'rm -rf "$dir"' EXIT
  for f in "$tests"/*.sql; do
    sed "s#127\.0\.0\.1:8088#$addr#g" "$f" >"$dir/$(basename "$f")"
  done
fi

# Every file runs, also after an earlier one failed, so one CI run reports
# every failing file instead of only the first; the script still exits 1
# when any file (or cleanup.sql) failed, and lists them at the end. Files
# are independent fixtures (each creates or reuses its own named rows), and
# cleanup.sql runs last either way.

failed=()
for f in "${files[@]}"; do
  echo "== tests/$f.sql"
  if ! psql -X -q -v ON_ERROR_STOP=1 -f "$dir/$f.sql" >/dev/null; then
    echo "FAILED: tests/$f.sql" >&2
    failed+=("tests/$f.sql")
  fi
done

echo "== tests/cleanup.sql"
psql -X -q -v ON_ERROR_STOP=1 -f "$dir/cleanup.sql" >/dev/null || { echo "FAILED: tests/cleanup.sql" >&2; failed+=("tests/cleanup.sql"); }

if [[ ${#failed[@]} -eq 0 ]]; then
  echo "SQL tests passed."
  exit 0
fi
echo "SQL tests FAILED: ${#failed[@]} of $(( ${#files[@]} + 1 )) files:" >&2
printf '  %s\n' "${failed[@]}" >&2
exit 1
