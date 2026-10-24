#!/usr/bin/env bash
# Automated logical dump/restore test (two-pass restore) on throwaway clusters.
#
#   1. Source cluster: CREATE EXTENSION, fixture rows across the user-state
#      tables, a user logs in over the web RPC and chats with an agent
#      (reply from the built-in mock, harvested by the worker), and a user
#      procedure call is harvested by the worker.
#   2. pg_dumpall --globals-only + pg_dump -Fc, after pointing the worker
#      away from the database so the row counts and the dump agree.
#   3. Restore cluster (separate data directory, same allgres.secret_key):
#      globals, CREATE EXTENSION pgcrypto, pg_restore --schema-only,
#      pg_restore --data-only --disable-triggers, into a database the worker
#      is not attached to.
#   4. Assert: no restore errors, per-table row counts equal, no orphan
#      foreign keys, fixture rows present, fn_selftest() failed = 0.
#   5. Point the worker at the restored database and restart: a user
#      procedure call is harvested by the worker, the same user logs in again
#      over the web RPC and continues the same chat session (new reply
#      harvested through the worker from the mock).
#
# Everything lives under one mktemp directory that is removed on exit (pass
# or fail), so the script is rerunnable. It never touches another cluster.
# The clusters listen only on a Unix socket in that directory; the web
# worker binds ALLGRES_DR_HTTP_ADDR, which must be free while this runs.
#
# Environment:
#   PG_BIN               directory with initdb/pg_ctl/psql/pg_dump/pg_restore
#                        (default: the directory of pg_config on PATH)
#   ALLGRES_DR_HTTP_ADDR web/mock address for the test clusters
#                        (default 127.0.0.1:18088)
#   ALLGRES_DR_KEEP=1    keep the scratch directory for inspection
#   ALLGRES_DR_LOG_DIR   copy logs and counts here before cleanup
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PG_BIN="${PG_BIN:-$(pg_config --bindir)}"
http_addr="${ALLGRES_DR_HTTP_ADDR:-127.0.0.1:18088}"
base_url="http://$http_addr"
port=5432   # Unix socket only, inside the scratch directory
secret_key="dr-test-secret-$(date +%s)-$$"
src_db=allgres_dr_src
dst_db=allgres_dr_restored
idle_db=allgres_dr_idle
user_name=dr_user
user_pass=dr-user-password

scratch="$(mktemp -d "${TMPDIR:-/tmp}/allgres-dr.XXXXXX")"
sock="$scratch/sock"
mkdir -p "$sock"
log() { printf '==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stop_cluster() {
  local d="$1"
  if [[ -f "$d/postmaster.pid" ]]; then
    "$PG_BIN/pg_ctl" -D "$d" -m immediate -w stop >/dev/null 2>&1 || true
  fi
}
cleanup() {
  local rc=$?
  stop_cluster "$scratch/src"
  stop_cluster "$scratch/dst"
  if [[ -n "${ALLGRES_DR_LOG_DIR:-}" ]]; then
    mkdir -p "$ALLGRES_DR_LOG_DIR"
    cp "$scratch"/*.log "$scratch"/*.txt "$ALLGRES_DR_LOG_DIR"/ 2>/dev/null || true
  fi
  if [[ "${ALLGRES_DR_KEEP:-0}" == 1 ]]; then
    echo "scratch kept: $scratch"
  else
    rm -rf "$scratch"
  fi
  if [[ $rc -eq 0 ]]; then echo "dump/restore test: PASS"; else echo "dump/restore test: FAIL (rc=$rc)"; fi
  exit $rc
}
trap cleanup EXIT

# psql against the throwaway cluster only (no PG* environment leaks in).
q() { local db="$1"; shift; env -u PGHOST -u PGPORT -u PGUSER -u PGDATABASE -u PGSERVICE \
        "$PG_BIN/psql" -X -q -v ON_ERROR_STOP=1 -h "$sock" -p "$port" -d "$db" "$@"; }
qv() { local db="$1"; shift; q "$db" -tAc "$@"; }

init_cluster() {
  local d="$1"
  "$PG_BIN/initdb" -D "$d" --auth=trust -U "$(id -un)" >"$scratch/initdb-$(basename "$d").log" 2>&1
  cat >>"$d/postgresql.conf" <<CONF
port = $port
listen_addresses = ''
unix_socket_directories = '$sock'
shared_preload_libraries = 'allgres'
allgres.secret_key = '$secret_key'
CONF
}

# The worker attaches to ALLGRES_DATABASE, read once at postmaster start.
start_cluster() {
  local d="$1" worker_db="$2"
  env -u ALLGRES_DASHBOARD_TOKEN -u ALLGRES_BOOTSTRAP_ADMIN_USER -u ALLGRES_BOOTSTRAP_ADMIN_PASSWORD \
      -u ALLGRES_SOCKET_DIR \
      ALLGRES_DATABASE="$worker_db" ALLGRES_HTTP_ADDR="$http_addr" ALLGRES_ENABLE_MOCK=1 \
      ALLGRES_RATE_LIMIT_PER_MINUTE=600 \
      "$PG_BIN/pg_ctl" -D "$d" -l "$scratch/$(basename "$d")-server.log" -w start >/dev/null
}
restart_cluster() { stop_cluster "$1"; start_cluster "$1" "$2"; }

http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 1 "$base_url/" 2>/dev/null || true; }
# Web worker answering, and the runtime worker's RPC socket bound.
wait_http() {
  for _ in $(seq 1 150); do
    [[ "$(http_code)" != 000 && -S "$1/allgres/runtime.sock" ]] && return 0
    sleep 0.2
  done
  fail "web/runtime worker not ready on $base_url ($1/allgres/runtime.sock)"
}

rpc() {
  curl -sS -X POST "$base_url/api/v1/rpc" \
    -H 'Content-Type: application/json' -H 'X-Allgres-Client: dump-restore-test' \
    --data "$1"
}

login() {
  local r token
  # The runtime worker notices a new CREATE EXTENSION on its next loop; until
  # then the RPC answers extension_not_installed.
  for _ in $(seq 1 100); do
    r="$(rpc "$(jq -nc --arg u "$user_name" --arg p "$user_pass" '{action:"auth.login",username:$u,password:$p}')")"
    grep -Eq 'extension_not_installed|runtime unavailable' <<<"$r" || break
    sleep 0.2
  done
  token="$(jq -r '.session_token // empty' <<<"$r")"
  [[ -n "$token" ]] || fail "auth.login failed: $r"
  printf '%s' "$token"
}

# Send one chat message; wait until chat.history holds $2 mock replies.
chat_and_wait() {
  local token="$1" want="$2" agent="$3" r sid n
  r="$(rpc "$(jq -nc --arg t "$token" --arg a "$agent" '{action:"chat.send",session_token:$t,agent_id:$a,message:"Return the Allgres MVP mock answer."}')")"
  sid="$(jq -r '.session_id // empty' <<<"$r")"
  [[ -n "$sid" ]] || fail "chat.send failed: $r"
  for _ in $(seq 1 150); do
    r="$(rpc "$(jq -nc --arg t "$token" --arg a "$agent" '{action:"chat.history",session_token:$t,agent_id:$a}')")"
    n="$(jq '[.messages[] | select(.role == "assistant" and (.content | contains("Allgres mock runtime OK")))] | length' <<<"$r")"
    [[ "$n" -ge "$want" ]] && { printf '%s' "$sid"; return 0; }
    sleep 0.2
  done
  fail "no mock reply #$want in chat.history: $r"
}

# Row count of every allgres_private table, plus the dump coverage list.
counts() {
  q "$1" -tA <<'SQL'
SELECT format('SELECT %L || ''|'' || count(*) FROM allgres_private.%I', c.relname, c.relname)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'allgres_private' AND c.relkind IN ('r', 'p')
  AND c.relname NOT IN ('web_sessions', 'oauth_states', 'sql_function_allowlist',
                        'provider_probes', 'embedding_calls', 'local_execution_context')
ORDER BY c.relname
\gexec
SQL
}

for tool in initdb pg_ctl psql pg_dump pg_dumpall pg_restore; do
  [[ -x "$PG_BIN/$tool" ]] || fail "$PG_BIN/$tool not found (set PG_BIN)"
done
command -v jq >/dev/null || fail "jq is required"
command -v curl >/dev/null || fail "curl is required"
if [[ "$(http_code)" != 000 ]]; then
  fail "$base_url is already serving; stop that cluster or set ALLGRES_DR_HTTP_ADDR"
fi

log "scratch: $scratch (PG_BIN=$PG_BIN, web=$base_url)"

# ---------------------------------------------------------------- source
log "source cluster: init, worker on $src_db"
init_cluster "$scratch/src"
# The worker connects once at start, so its database must exist first.
start_cluster "$scratch/src" postgres
q postgres -c "CREATE DATABASE $src_db" -c "CREATE DATABASE $idle_db"
restart_cluster "$scratch/src" "$src_db"
q "$src_db" -c "CREATE EXTENSION pgcrypto" -c "CREATE EXTENSION allgres"
wait_http "$scratch/src"
q "$src_db" -v mock_base="$base_url/mock" -f "$root/tests/dump_restore_fixture.sql" >"$scratch/fixture.log"
chat_agent="$(qv "$src_db" "SELECT agent_id FROM allgres_private.agents WHERE name = 'dr_chat_agent'")"

log "source: login over the web RPC, first chat turn"
token="$(login)"
chat_session="$(chat_and_wait "$token" 1 "$chat_agent")"
log "source: chat session $chat_session answered by the mock"
# Rows that hang off a real session: the project chat link and finished
# function/procedure call records (harvested, so no worker picks them up).
q "$src_db" -v sid="$chat_session" >>"$scratch/fixture.log" <<'SQL'
INSERT INTO allgres_private.user_project_chat_sessions (user_id, project_id, session_id)
SELECT u.user_id, p.project_id, :'sid'::uuid
FROM allgres_private.users u, allgres_private.projects p
WHERE u.username = 'dr_user' AND p.name = 'dr-project';
INSERT INTO allgres_private.function_calls (task_id, function_id, agent_id, status, result)
SELECT t.task_id, f.function_id, t.agent_id, 'harvested', '{"fixture": true}'::jsonb
FROM allgres_private.tasks t, allgres_private.functions f
WHERE t.session_id = :'sid'::uuid AND t.parent_task_id IS NULL AND f.name = 'dr_user_fn';
INSERT INTO allgres_private.procedure_calls (task_id, procedure_id, agent_id, status, result)
SELECT t.task_id, p.procedure_id, t.agent_id, 'harvested', '{"fixture": true}'::jsonb
FROM allgres_private.tasks t, allgres_private.procedures p
WHERE t.session_id = :'sid'::uuid AND t.parent_task_id IS NULL AND p.name = 'dr-fx-proc';
SQL
q "$src_db" -f "$root/tests/dump_restore_exec.sql" >"$scratch/exec-source.log" 2>&1 \
  || { cat "$scratch/exec-source.log"; fail "executor reach on the source database"; }
log "source: user procedure call harvested by the worker"
[[ "$(qv "$src_db" "SELECT count(*) FROM allgres_private.web_sessions")" -ge 1 ]] || fail "no web session on source"

log "source: point the worker at $idle_db so counts and the dump agree"
restart_cluster "$scratch/src" "$idle_db"
counts "$src_db" >"$scratch/counts-source.txt"
"$PG_BIN/pg_dumpall" -h "$sock" -p "$port" --globals-only -f "$scratch/globals.sql"
"$PG_BIN/pg_dump" -h "$sock" -p "$port" -d "$src_db" -Fc -f "$scratch/backup.dump" 2>"$scratch/pg_dump.log"
counts "$src_db" >"$scratch/counts-source-after.txt"
cmp -s "$scratch/counts-source.txt" "$scratch/counts-source-after.txt" || fail "source changed during the dump"
"$PG_BIN/pg_restore" -l "$scratch/backup.dump" >"$scratch/dump-toc.txt"
stop_cluster "$scratch/src"

# --------------------------------------------------------------- restore
log "restore cluster: init, worker on the empty postgres database"
init_cluster "$scratch/dst"
start_cluster "$scratch/dst" postgres
q postgres -f "$scratch/globals.sql" >"$scratch/globals-restore.log" 2>&1 || true
# The only acceptable globals errors: the bootstrap superuser already exists.
if grep -E 'ERROR' "$scratch/globals-restore.log" | grep -v "role \"$(id -un)\" already exists" | grep -q .; then
  cat "$scratch/globals-restore.log"; fail "globals restore"
fi
q postgres -c "CREATE DATABASE $dst_db"
q "$dst_db" -c "CREATE EXTENSION pgcrypto"
log "restore pass 1: pg_restore --schema-only"
"$PG_BIN/pg_restore" -h "$sock" -p "$port" -d "$dst_db" --schema-only --exit-on-error \
  "$scratch/backup.dump" >"$scratch/restore-schema.log" 2>&1 \
  || { cat "$scratch/restore-schema.log"; fail "pg_restore --schema-only"; }
log "restore pass 2: pg_restore --data-only --disable-triggers"
"$PG_BIN/pg_restore" -h "$sock" -p "$port" -d "$dst_db" --data-only --disable-triggers --exit-on-error \
  "$scratch/backup.dump" >"$scratch/restore-data.log" 2>&1 \
  || { cat "$scratch/restore-data.log"; fail "pg_restore --data-only --disable-triggers"; }
if grep -Eiq 'error|duplicate key' "$scratch/restore-schema.log" "$scratch/restore-data.log"; then
  cat "$scratch/restore-schema.log" "$scratch/restore-data.log"; fail "pg_restore reported errors"
fi

counts "$dst_db" >"$scratch/counts-restore.txt"
if ! diff "$scratch/counts-source.txt" "$scratch/counts-restore.txt" >"$scratch/counts-diff.txt"; then
  cat "$scratch/counts-diff.txt"; fail "row counts differ between source and restore"
fi
log "row counts equal in $(wc -l <"$scratch/counts-source.txt") tables"
q "$dst_db" -f "$root/tests/dump_restore_verify.sql" >"$scratch/verify.log" 2>&1 \
  || { cat "$scratch/verify.log"; fail "verify"; }
grep -h 'NOTICE' "$scratch/verify.log" | sed 's/^/    /'

# ------------------------------------------- restored database in service
log "restore: point the worker at $dst_db and restart"
restart_cluster "$scratch/dst" "$dst_db"
wait_http "$scratch/dst"
selftest="$(qv "$dst_db" "SELECT allgres_public.fn_selftest()")"
st_failed="$(jq -r '.failed' <<<"$selftest")"
echo "$selftest" >"$scratch/selftest-restored.txt"
log "restore: fn_selftest passed $(jq -r '.passed' <<<"$selftest"), failed $st_failed"
[[ "$st_failed" == 0 ]] || { jq '[.cases[] | select(.ok == false)]' <<<"$selftest"; fail "selftest on the restored database"; }

q "$dst_db" -f "$root/tests/dump_restore_exec.sql" >"$scratch/exec-restore.log" 2>&1 \
  || { cat "$scratch/exec-restore.log"; fail "executor reach on the restored database"; }
log "restore: user procedure call harvested by the worker on $dst_db"

token2="$(login)"
[[ "$token2" != "$token" ]] || fail "login returned the pre-dump token"
again="$(chat_and_wait "$token2" 2 "$chat_agent")"
[[ "$again" == "$chat_session" ]] || fail "chat.send opened session $again instead of continuing $chat_session"
log "restore: $user_name logged in again and continued chat session $chat_session (second mock reply harvested)"
