#!/bin/sh
set -eu

# Run inside an ephemeral Fedora 43 container or the CI Fedora job.
cd "${GITHUB_WORKSPACE:-/src}"
dnf install -y rpm-build rpmdevtools rpmlint cargo rustfmt gcc clang openssl-devel pkgconf-pkg-config git tar gzip postgresql-server-devel postgresql-server
rpmdev-setuptree
rpm_topdir="$(rpm --eval '%{_topdir}')"
git -c safe.directory="$(pwd)" archive --format=tar --prefix=allgres-0.1.0/ \
  -o "$rpm_topdir/SOURCES/allgres-0.1.0.tar" HEAD
gzip "$rpm_topdir/SOURCES/allgres-0.1.0.tar"
if tar -tzf "$rpm_topdir/SOURCES/allgres-0.1.0.tar.gz" | grep -E '(^|/)(\.git|\.env|target|node_modules|test-results|allgres-agent-dev-pgdata)(/|$)'; then
  echo 'RPM source archive contains local or generated data' >&2
  exit 1
fi
rpmbuild -ba packaging/rpm/allgres.spec
rpmlint "$rpm_topdir"/RPMS/*/allgres-*.rpm
rpm -qpl "$rpm_topdir"/RPMS/*/allgres-*.rpm | grep -E 'allgres\.(so|control)|allgres--.*\.sql'
