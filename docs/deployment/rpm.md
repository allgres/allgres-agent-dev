# RPM package

The public alpha builds a PostgreSQL 18 RPM on Fedora 43 from `packaging/rpm/allgres.spec`.
The RPM contains only the extension library, control file, generated install
SQL, license, and operator documentation. It does not contain provider keys,
database data, build caches, or source history.

The build intentionally leaves `pgcrypto` and `pgvector` optional. Install
the matching PostgreSQL contrib package for pgcrypto and a PostgreSQL 18
pgvector package for HNSW acceleration;
Allgres keeps its exact-array search fallback when pgvector is unavailable.

CI runs `rpmlint` and inspects the resulting package contents in a clean Fedora
environment before a release may publish it. Installation testing remains a
release gate. Release publication remains a
separate, tag-gated workflow.
