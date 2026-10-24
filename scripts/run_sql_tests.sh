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
files=(smoke execution_safety execution_safety_worker e2e_mock capability_governance capability_search_e2e procedure_binding_e2e fixed_url_procedure_e2e legacy_reserved_name_row schedule_worker_e2e)

dir="$root/tests"
if [[ "$addr" != "127.0.0.1:8088" ]]; then
  dir=$(mktemp -d)
  trap 'rm -rf "$dir"' EXIT
  for f in "$root"/tests/*.sql; do
    sed "s#127\.0\.0\.1:8088#$addr#g" "$f" >"$dir/$(basename "$f")"
  done
fi

rc=0
for f in "${files[@]}"; do
  echo "== tests/$f.sql"
  if ! psql -X -q -v ON_ERROR_STOP=1 -f "$dir/$f.sql" >/dev/null; then
    echo "FAILED: tests/$f.sql" >&2
    rc=1
    break
  fi
done

echo "== tests/cleanup.sql"
psql -X -q -v ON_ERROR_STOP=1 -f "$dir/cleanup.sql" >/dev/null || { echo "FAILED: tests/cleanup.sql" >&2; rc=1; }

[[ $rc -eq 0 ]] && echo "SQL tests passed."
exit $rc
