# Open alpha readiness

## Completed in the first hardening batch

- Session reads now distinguish ownership from agent assignment; operators retain monitoring access.
- Last-active-admin changes are serialized to prevent concurrent demotion or deactivation.
- Self-test failures include null results, and the frozen RPC catalog covers Capability operations.
- Capability discovery indexes Agents, Functions, Procedures, and plan templates with permission-first hybrid search, embedding provenance, audit events, and measurable outcomes.
- Capability execution continues through the existing permission and approval paths. Discovery never executes a candidate by itself.
- The Settings UI exposes index, embedding, draft, and search status. Provider forms save before OAuth starts and enforce supported provider purposes.
- The order-review example proves a generated Function and Procedure can build and execute under an Agent database role without an external service.

## Remaining alpha gates

- Finish the agreed Dashboard / Chat / SQL / Settings information-architecture migration, including replacing separate Messenger and Run modes with a single General chat and explicit session history.
- Add browser-level role and three-click navigation regression tests for operator and regular-user accounts.
- Expand Capability outcome linkage to HTTP and MCP calls; this batch records discovery and the built-in Function/Procedure path.
- Add the reviewed Draft-to-Published promotion workflow, isolated evaluation comparison, version rollback controls, and operator approval screens. The schema deliberately prevents discovery from acting as automatic publication.
- Decide whether per-user model preferences should remain able to update shared Agent configuration.
- Complete MCP protocol initialization and production-grade cost and latency attribution.
- Re-run packaging and deployment-specific validation before publishing Docker, CNPG, or RPM artifacts.

No production migration, image publication, remote branch update, or deployment is part of this batch.
