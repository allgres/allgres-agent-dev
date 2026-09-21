Name:           allgres
Version:        0.1.0
Release:        0.alpha.1%{?dist}
Summary:        PostgreSQL-native agent control plane
License:        Apache-2.0
URL:            https://github.com/allgres/allgres-agent
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  cargo
BuildRequires:  clang
BuildRequires:  gcc
BuildRequires:  openssl-devel
BuildRequires:  pkgconfig
BuildRequires:  postgresql17-devel
Requires:       postgresql17-server

%description
Allgres packages an agent runtime and control plane as a PostgreSQL extension.
pgvector and pgcrypto remain optional runtime extensions.

%prep
%autosetup

%build
export PATH="$HOME/.cargo/bin:$PATH"
cargo install --locked cargo-pgrx --version 0.19.2
cargo pgrx init --pg17=/usr/pgsql-17/bin/pg_config
cargo pgrx package --release --no-default-features --features pg17 \
  --pg-config /usr/pgsql-17/bin/pg_config

%install
install -d %{buildroot}/usr/pgsql-17/lib
install -d %{buildroot}/usr/pgsql-17/share/extension
install -m 0755 "$(find target/release/allgres-pg17 -name allgres.so -print -quit)" \
  %{buildroot}/usr/pgsql-17/lib/allgres.so
find target/release/allgres-pg17 -type f \( -name 'allgres.control' -o -name 'allgres--*.sql' \) \
  -exec install -m 0644 {} %{buildroot}/usr/pgsql-17/share/extension/ \;

%files
%license LICENSE
%doc README.md SECURITY.md
/usr/pgsql-17/lib/allgres.so
/usr/pgsql-17/share/extension/allgres.control
/usr/pgsql-17/share/extension/allgres--*.sql

%changelog
* Mon Sep 21 2026 Allgres Maintainers <maintainers@allgres.io> - 0.1.0-0.alpha.1
- Initial public alpha package
