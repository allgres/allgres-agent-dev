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
- User Provider/Model preferences are isolated per user and Agent; shared Agent defaults remain administrator-owned and are used by schedules and users without an override.
- Capability discovery now has explicit testing/review/publication states, immutable-published transition rules, version snapshots, operator publication, and rollback controls.

## Remaining alpha gates

- Add browser-level role and three-click navigation regression tests for operator and regular-user accounts.
- Expand Capability outcome linkage to HTTP and MCP calls; this batch records discovery and the built-in Function/Procedure path.
- Connect the Capability review screen to a real isolated-evaluation runner and baseline comparison; publication currently requires an operator-supplied passing result rather than fabricating or automatically running one.
- Complete stateful MCP protocol initialization/capability negotiation and production-grade cost attribution. Stateless MCP-over-HTTP calls, error outcomes, latency, OAuth refresh, and secret masking are already covered.
- Re-run packaging and deployment-specific validation before publishing Docker, CNPG, or RPM artifacts.

No production migration, image publication, remote branch update, or deployment is part of this batch.
