#!/usr/bin/env bash
# Run a command where host-name lookups fail like they do on a CI runner
# for names that cannot exist, without touching the host system.
#
#   scripts/with_nodns.sh COMMAND [ARG...]
#
#   # a test cluster whose backends and workers cannot resolve .invalid:
#   scripts/with_nodns.sh pg_ctl -D "$PGDATA" -l "$PGDATA/log" start
#   ./scripts/run_sql_tests.sh                       # clients need nothing
#   # the dump/restore test starts its own clusters, so wrap the script:
#   scripts/with_nodns.sh ./scripts/run_dump_restore_test.sh
#
# Why: the DNS tests (tests/require_failing_dns.sql) need .invalid lookups to
# fail. Some sandboxes run a resolver that answers every name; there they
# stop with "environment unsuitable: resolver answers .invalid names".
#
# How: COMMAND runs in a private mount namespace in which /etc/nsswitch.conf
# is a bind-mounted copy whose "hosts:" line is "files" -- /etc/hosts
# (localhost) still resolves, nothing else does, and glibc reports what a CI
# runner reports for .invalid ("Name or service not known"). Only processes
# started under COMMAND see it (a postmaster started here keeps it after
# this script exits); the real /etc/nsswitch.conf is never written, and the
# namespace disappears with its last process.
#
# Requirements: Linux, util-linux >= 2.38 unshare, glibc. Unprivileged by
# default, through user namespaces (kernel.unprivileged_userns_clone and no
# AppArmor userns restriction): an outer user namespace maps you to root
# only to make the bind mount, then a nested one maps you back to your own
# uid/gid, so COMMAND runs as you (PostgreSQL refuses to run as root) and
# owns the same files. Supplementary groups show as "nogroup" inside. If
# user namespaces are unavailable and `sudo -n` works, it falls back to
# `sudo unshare -m` + setpriv back to your uid/gid (ALLGRES_NODNS_MODE=sudo
# forces that, =userns forbids it). CI runners need none of this: their
# resolver already fails .invalid lookups.
set -euo pipefail

if [[ $# -eq 0 || "$1" == -h || "$1" == --help ]]; then
  sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
  exit 2
fi

uid=$(id -u); gid=$(id -g)
conf=$(mktemp "${TMPDIR:-/tmp}/allgres-nsswitch.XXXXXX")
chmod 644 "$conf"
# Keep every other database (passwd, group, ...) as the host has it.
if [[ -r /etc/nsswitch.conf ]]; then
  grep -v '^[[:space:]]*hosts:' /etc/nsswitch.conf >"$conf" || true
fi
echo 'hosts: files' >>"$conf"

# Runs inside the new mount namespace (as root of it): bind the copy, drop
# the temp file (the mount keeps its inode), check, then exec $3 "$@".
inner='set -e
conf=$1; shift
mount --bind "$conf" /etc/nsswitch.conf
rm -f "$conf"
if getent hosts allgres-nodns-selfcheck.allgres-test.invalid >/dev/null; then
  echo "with_nodns.sh: .invalid still resolves inside the namespace" >&2; exit 1
fi
exec "$@"'

mode=${ALLGRES_NODNS_MODE:-auto}
if [[ $mode != sudo ]] && unshare --user --map-root-user true 2>/dev/null; then
  exec unshare --user --map-root-user --mount --propagation private \
    sh -c "$inner" sh "$conf" \
    unshare --user --map-user="$uid" --map-group="$gid" -- "$@"
fi
if [[ $mode != userns ]] && sudo -n true 2>/dev/null; then
  echo "with_nodns.sh: using sudo unshare (user namespaces unavailable or ALLGRES_NODNS_MODE=sudo)" >&2
  exec sudo --preserve-env unshare --mount --propagation private \
    sh -c "$inner" sh "$conf" \
    setpriv --reuid="$uid" --regid="$gid" --init-groups -- env PATH="$PATH" "$@"
fi
rm -f "$conf"
echo "with_nodns.sh: needs unprivileged user namespaces or passwordless sudo (see --help)" >&2
exit 1
