#!/bin/sh
set -eu

# Run inside an ephemeral Fedora 43 container or the CI Fedora job.
# Resolve the checkout from this script so it works in both mount layouts.
cd "$(dirname "$0")/../.."
dnf install -y rpm-build rpmdevtools rpmlint cargo rustfmt gcc clang openssl-devel pkgconf-pkg-config git tar gzip postgresql-server-devel postgresql-server
rpmdev-setuptree
rpm_topdir="$(rpm --eval '%{_topdir}')"
source_tar="$rpm_topdir/SOURCES/allgres-0.1.0.tar"
if git -c safe.directory="$(pwd)" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -c safe.directory="$(pwd)" archive --format=tar --prefix=allgres-0.1.0/ \
    -o "$source_tar" HEAD
elif [ "${GITHUB_ACTIONS:-}" = true ]; then
  # Checkout in a container job can expose the files without .git. Its clean
  # workspace is still sufficient for a source archive; exclude local output.
  tar --exclude='./.git' --exclude='./target' --exclude='./node_modules' \
    --exclude='./test-results' --exclude='./*-pgdata' --exclude='./.env*' \
    --transform='s,^\./,allgres-0.1.0/,' -cf "$source_tar" .
else
  echo 'Expected a Git checkout to build the RPM source archive' >&2
  exit 1
fi
gzip "$rpm_topdir/SOURCES/allgres-0.1.0.tar"
if tar -tzf "$rpm_topdir/SOURCES/allgres-0.1.0.tar.gz" | grep -E '(^|/)(\.git|\.env|target|node_modules|test-results|allgres-agent-pgdata)(/|$)'; then
  echo 'RPM source archive contains local or generated data' >&2
  exit 1
fi
rpmbuild -ba packaging/rpm/allgres.spec
rpmlint "$rpm_topdir"/RPMS/*/allgres-*.rpm
rpm -qpl "$rpm_topdir"/RPMS/*/allgres-*.rpm | grep -E 'allgres\.(so|control)|allgres--.*\.sql'
