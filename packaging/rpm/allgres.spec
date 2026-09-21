Name:           allgres
Version:        0.1.0
Release:        0.alpha.1%{?dist}
Summary:        PostgreSQL-native agent control plane
License:        Apache-2.0
URL:            https://github.com/allgres/allgres-agent
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  cargo
BuildRequires:  rustfmt
BuildRequires:  clang
BuildRequires:  gcc
BuildRequires:  openssl-devel
BuildRequires:  pkgconfig
BuildRequires:  postgresql-server-devel >= 18
Requires:       postgresql-server >= 18

%description
Allgres packages an agent runtime and control plane as a PostgreSQL extension.
Vector search and cryptographic helpers remain optional runtime extensions.

%prep
%autosetup

%build
export PATH="$HOME/.cargo/bin:$PATH"
cargo install --locked cargo-pgrx --version 0.19.2
cargo pgrx init --pg18=/usr/sbin/pg_config
cargo pgrx package --no-default-features --features pg18 \
  --pg-config /usr/sbin/pg_config

%install
install -d %{buildroot}/usr/lib64/pgsql
install -d %{buildroot}/usr/share/pgsql/extension
install -m 0755 target/release/allgres-pg18/usr/lib64/pgsql/allgres.so \
  %{buildroot}/usr/lib64/pgsql/allgres.so
find target/release/allgres-pg18/usr/share/pgsql/extension -type f \( -name 'allgres.control' -o -name 'allgres--*.sql' \) \
  -exec install -m 0644 {} %{buildroot}/usr/share/pgsql/extension/ \;

%files
%license LICENSE
%doc README.md SECURITY.md
/usr/lib64/pgsql/allgres.so
/usr/share/pgsql/extension/allgres.control
/usr/share/pgsql/extension/allgres--*.sql

%changelog
* Mon Sep 21 2026 Allgres Maintainers <maintainers@allgres.io> - 0.1.0-0.alpha.1
- Initial public alpha package
