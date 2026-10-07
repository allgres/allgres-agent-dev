# Known limitations

Allgres `0.1.0-alpha.3` is a public alpha. Use it for evaluation and
development, not as the only copy of production data.

## Upgrade compatibility

The alpha does not provide extension upgrade scripts. Install it into a new
database. Until the first stable release, schema and API compatibility may
change between alpha versions.

## Deployment coverage

- PostgreSQL 16, 17, and 18 are covered by CI.
- The bundled Docker image uses PostgreSQL 17.
- The CNPG example requires PostgreSQL 18 and Kubernetes Image Volume support.
  It is an example manifest, not a production-ready Helm chart.
- A Fedora 43 / PostgreSQL 18 RPM is published with the alpha release. DEB
  packages and a general-purpose Kubernetes deployment chart are not available.

## Security posture

- The zero-configuration Docker setup is intentionally limited to loopback.
  Set a dashboard token, secret key, and strong PostgreSQL password before
  exposing it beyond a local machine.
- TLS termination and network policy are deployment responsibilities.
- `pgcrypto` is required to encrypt provider credentials at rest.
- The operator audit log records application-level actor information; retain
  PostgreSQL and platform audit logs for security investigations.

## Optional capabilities

- `pgvector` accelerates semantic search but is not required.
- Helm charts and a native package repository are planned after the alpha.

Please report defects through GitHub Issues. Report vulnerabilities using the
private process in [SECURITY.md](SECURITY.md).
