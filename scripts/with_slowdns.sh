#!/usr/bin/env bash
# Run a command where every DNS lookup hangs (the nameserver never answers),
# without touching the host system. For the MANUAL check that
# allgres.resolve_host_addresses stays bounded and interruptible (see
# docs/testing.md, "Bounds of resolve_host_addresses").
#
#   scripts/with_slowdns.sh COMMAND [ARG...]
#
#   scripts/with_slowdns.sh pg_ctl -D "$PGDATA" -l "$PGDATA/log" start
#   ./scripts/check_resolve_interrupt.sh             # clients need nothing
#
# How: like scripts/with_nodns.sh, COMMAND runs in a private mount namespace,
# here with two bind-mounted copies: /etc/nsswitch.conf whose "hosts:" line
# is "files dns", and /etc/resolv.conf naming one nameserver that does not
# answer (default 192.0.2.1, RFC 5737 TEST-NET-1) with a long timeout.
# /etc/hosts (localhost) still resolves; every other lookup waits for the
# resolver timeout. Only processes started under COMMAND see it (a
# postmaster started here keeps it after this script exits); the host files
# are never written.
#
# Environment:
#   ALLGRES_SLOWDNS_NAMESERVER  nameserver that never answers (default 192.0.2.1)
#   ALLGRES_SLOWDNS_TIMEOUT     resolver timeout in seconds (default 30)
#   ALLGRES_NODNS_MODE          auto|userns|sudo, as for scripts/with_nodns.sh
#
# Requirements: as scripts/with_nodns.sh (Linux, util-linux >= 2.38, glibc,
# unprivileged user namespaces or passwordless sudo), plus a network on which
# packets to the nameserver are dropped rather than refused -- a refusal
# fails the lookup at once, and the self-check below then stops.
set -euo pipefail

if [[ $# -eq 0 || "$1" == -h || "$1" == --help ]]; then
  sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
  exit 2
fi

ns=${ALLGRES_SLOWDNS_NAMESERVER:-192.0.2.1}
to=${ALLGRES_SLOWDNS_TIMEOUT:-30}
uid=$(id -u); gid=$(id -g)
nss=$(mktemp "${TMPDIR:-/tmp}/allgres-nsswitch.XXXXXX")
res=$(mktemp "${TMPDIR:-/tmp}/allgres-resolv.XXXXXX")
chmod 644 "$nss" "$res"
if [[ -r /etc/nsswitch.conf ]]; then
  grep -v '^[[:space:]]*hosts:' /etc/nsswitch.conf >"$nss" || true
fi
echo 'hosts: files dns' >>"$nss"
printf 'nameserver %s\noptions timeout:%s attempts:1\n' "$ns" "$to" >"$res"

# Runs inside the new mount namespace (as root of it): bind both copies,
# drop the temp files, check that a lookup really hangs, then exec.
inner='set -e
nss=$1; res=$2; shift 2
mount --bind "$nss" /etc/nsswitch.conf
mount --bind "$res" /etc/resolv.conf
rm -f "$nss" "$res"
getent hosts localhost >/dev/null || { echo "with_slowdns.sh: localhost does not resolve from /etc/hosts" >&2; exit 1; }
rc=0; timeout 2 getent hosts allgres-slowdns-selfcheck.allgres-test.invalid >/dev/null || rc=$?
if [ "$rc" -ne 124 ]; then
  echo "with_slowdns.sh: a lookup did not hang (getent exit $rc); the nameserver answers or is refused here" >&2; exit 1
fi
exec "$@"'

cleanup() { rm -f "$nss" "$res"; }
mode=${ALLGRES_NODNS_MODE:-auto}
if [[ $mode != sudo ]] && unshare --user --map-root-user true 2>/dev/null; then
  exec unshare --user --map-root-user --mount --propagation private \
    sh -c "$inner" sh "$nss" "$res" \
    unshare --user --map-user="$uid" --map-group="$gid" -- "$@"
fi
if [[ $mode != userns ]] && sudo -n true 2>/dev/null; then
  echo "with_slowdns.sh: using sudo unshare (user namespaces unavailable or ALLGRES_NODNS_MODE=sudo)" >&2
  exec sudo --preserve-env unshare --mount --propagation private \
    sh -c "$inner" sh "$nss" "$res" \
    setpriv --reuid="$uid" --regid="$gid" --init-groups -- env PATH="$PATH" "$@"
fi
cleanup
echo "with_slowdns.sh: needs unprivileged user namespaces or passwordless sudo (see --help)" >&2
exit 1
