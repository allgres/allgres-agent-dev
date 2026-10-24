#!/usr/bin/env bash
# MANUAL check that allgres.resolve_host_addresses stays bounded and
# interruptible when the resolver never answers. Run it against a server
# started under scripts/with_slowdns.sh (libpq env: PGHOST, PGPORT, PGUSER,
# PGDATABASE; a superuser or allgres_owner, the only roles that may call the
# probe). See docs/testing.md, "Bounds of resolve_host_addresses".
#
#   scripts/with_slowdns.sh pg_ctl -D "$PGDATA" -l "$PGDATA/log" start
#   ./scripts/check_resolve_interrupt.sh
#
# Checks (exit 1 on the first that does not hold):
#   1. localhost resolves (from /etc/hosts), at once
#   2. SET statement_timeout = '1s'  -> 57014 after ~1 s     (bound: < 2.5 s)
#   3. pg_cancel_backend after 1 s    -> 57014 after ~1 s     (bound: < 2.5 s)
#   4. no statement_timeout           -> 58000 "did not finish within 5 s"
#                                        after ~5 s           (bound: 4.5-8 s)
set -euo pipefail

ms() { echo $(( $(date +%s%N) / 1000000 )); }
name() { echo "allgres-slow-$1-$RANDOM$RANDOM.allgres-test.invalid"; }
q() { psql -X -q -At -v ON_ERROR_STOP=1 -v VERBOSITY=verbose "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
# check LABEL ELAPSED_MS OUTPUT SQLSTATE MIN_MS MAX_MS
check() {
  echo "$1: ${2} ms; $(grep -m1 -E 'ERROR|^\{' <<<"$3" || echo "$3")"
  grep -q "ERROR:  $4:" <<<"$3" || fail "$1: expected SQLSTATE $4"
  (( $2 >= $5 && $2 <= $6 )) || fail "$1: took $2 ms, expected $5-$6 ms"
}

t=$(ms); out=$(q -c "SELECT allgres.resolve_host_addresses('localhost')" 2>&1) || fail "localhost: $out"; e=$(( $(ms) - t ))
echo "localhost: ${e} ms; $out"
[[ $out == *127.0.0.1* ]] || fail "localhost did not resolve"
(( e < 1000 )) || fail "localhost took $e ms"

t=$(ms); out=$(q -c "SET statement_timeout = '1s'" -c "SELECT allgres.resolve_host_addresses('$(name st)')" 2>&1) || true; e=$(( $(ms) - t ))
[[ $out == '{}' ]] && fail "lookup failed at once: is the server running under scripts/with_slowdns.sh?"
check "statement_timeout=1s" "$e" "$out" 57014 800 2500

tag=allgres_resolve_cancel_$$
t=$(ms)
q -c "SELECT '$tag', allgres.resolve_host_addresses('$(name cancel)')" >"${TMPDIR:-/tmp}/$tag.out" 2>&1 &
bg=$!
sleep 1
q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE query LIKE '%$tag%' AND pid <> pg_backend_pid()" >/dev/null
wait "$bg" || true; e=$(( $(ms) - t ))
out=$(cat "${TMPDIR:-/tmp}/$tag.out"); rm -f "${TMPDIR:-/tmp}/$tag.out"
check "pg_cancel_backend after 1s" "$e" "$out" 57014 800 2500

t=$(ms); out=$(q -c "SELECT allgres.resolve_host_addresses('$(name deadline)')" 2>&1) || true; e=$(( $(ms) - t ))
check "no timeout" "$e" "$out" 58000 4500 8000
grep -q 'did not finish within 5 s' <<<"$out" || fail "no timeout: expected 'did not finish within 5 s'"

echo "resolve_host_addresses bounds: all 4 checks passed"
