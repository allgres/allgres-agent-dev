# Open alpha readiness

## Completed in the first hardening batch

- Session reads now distinguish ownership from agent assignment; operators retain monitoring access.
- Last-active-admin changes are serialized to prevent concurrent demotion or deactivation.
- Self-test failures include null results, and the frozen RPC catalog covers Capability operations.
- Capability discovery indexes Agents, Functions, Procedures, and plan templates with permission-first hybrid search, embedding provenance, audit events, and measurable outcomes.
- Capability execution continues through the existing permission and approval paths. Discovery never executes a candidate by itself.
- The Settings UI exposes index, embedding, draft, and search status. Provider forms save before OAuth starts and enforce supported provider purposes.
- The order-review example proves a generated Function and Procedure can build and execute under an Agent database role without an external service.
- Navigation now follows Dashboard / Chat (General, Projects, Approvals) / SQL / Settings. General combines conversation, `@agent-name` routing, and session history; Projects combines management and conversation. Regular users receive only their scoped Chat and Agent settings surfaces.
- User Provider/Model preferences are isolated per user and Agent; shared Agent defaults remain administrator-owned and are used by schedules and users without an override. The legacy all-Agent bulk overwrite UI and RPC have been removed, and direct calls to the compatibility SQL function now fail closed.
- Capability discovery now has explicit testing/review/publication states, immutable-published transition rules, version snapshots, operator publication, and rollback controls.

## Final alpha gates in progress

- Browser role, direct-navigation, keyboard, and mobile regression tests run against an isolated real dashboard.
- Capability publication consumes a durable, content-hash-bound contract evaluation; dashboard callers cannot supply a fabricated pass flag. A full isolated behavioral runner with representative fixtures and baseline comparison is still required before public alpha.
- Function source has immutable generations and non-destructive rollback alongside Procedure history. Capability rollback restores the underlying source generation.
- Recall@5, selection accuracy, first-try success, correction, reuse, execution latency, and remote fixed-call cost are derived from audited search/execution evidence.
- Stateful MCP initialization, session propagation, initialized notification, stateless compatibility fallback, error separation, OAuth refresh/reconnect state, and secret masking have implementation and existing SQL coverage. A local stateful MCP server transport regression passes; a full worker/SQL-to-MCP integration regression remains pending.
- CI passed source builds on PostgreSQL 16/17/18, Docker, CNPG extension image build, Fedora 43 PostgreSQL 18 RPM build/lint, and the remaining browser and fault-injection jobs for the public alpha commit.
- Local `nerdctl` verification passed: PostgreSQL 17 Docker build, extension self-test (361 passed, 0 failed), SQL smoke and mock end-to-end flow, PostgreSQL 18 CNPG extension-image build, and Fedora 43 RPM build/lint/install.
- Live CNPG verification passed on Kubernetes 1.36.4/containerd 2.3.2 with CNPG 1.30.0 and PostgreSQL 18.6: versioned image mounted, declarative `CREATE EXTENSION`, 361 self-tests, runtime worker, and dashboard health check. The published RPM also started PostgreSQL 18.6 in a disposable Fedora 43 container and passed 361 self-tests with optional `pgcrypto` installed. Multi-instance failover and a host service upgrade were not tested.

Artifact publication, remote deployment, and production database migration remain deliberately tag/operator controlled; readiness checks do not publish anything.
