#!/bin/sh
set -eu

# Run inside an ephemeral Fedora 43 container or the CI Fedora job.
cd "${GITHUB_WORKSPACE:-/src}"
dnf install -y rpm-build rpmdevtools rpmlint cargo rustfmt gcc clang openssl-devel pkgconf-pkg-config tar gzip postgresql-server-devel postgresql-server
rpmdev-setuptree
rpm_topdir="$(rpm --eval '%{_topdir}')"
tar --exclude=.git --exclude=target --exclude=.env --exclude=node_modules --exclude=test-results \
  --transform 's,^,allgres-0.1.0/,' -czf "$rpm_topdir/SOURCES/allgres-0.1.0.tar.gz" .
rpmbuild -ba packaging/rpm/allgres.spec
rpmlint "$rpm_topdir"/RPMS/*/allgres-*.rpm
rpm -qpl "$rpm_topdir"/RPMS/*/allgres-*.rpm | grep -E 'allgres\.(so|control)|allgres--.*\.sql'
