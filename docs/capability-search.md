# Capability search and measured reuse

Allgres indexes active Agents, Functions, and Procedures as reusable
capabilities. The searchable document contains the stable name, description,
input metadata, build state, and usage constraints. A content hash invalidates
the embedding whenever that document changes. The configured
`purpose='embedding'` provider rebuilds it through the existing background
worker queue.

An Agent can return `{"action":"search_capabilities","query":"..."}`.
The query embedding is generated asynchronously, then hybrid semantic/text
ranking returns at most five candidates. SQL filters the candidate set before
ranking with the same `agent`, `function`, or `procedure` permission required
by the eventual operation. Search does not execute anything and cannot grant
authority. The Agent must subsequently choose `delegate`, `call_function`, or
`run_procedure`; those paths repeat their existing permission and build-state
checks.

Embeddings remain `double precision[]` as the portable source of truth. When
pgvector is installed, Allgres creates a dimension-specific HNSW expression
index automatically. Without pgvector, exact cosine ranking remains available.
The index records the provider and model so vectors from incompatible models
are never compared.

`capability_search_events` records the query, permission-filtered candidates,
model, latency, selection, and outcome fields needed for measurable
improvement. Raw secrets are never part of a search document. The first alpha
slice reports searches, selections, successes, failures, and latency; later
evaluation can derive Recall@K, selection accuracy, reuse, rejection, and
regression rates from labelled runs.

The lifecycle is deliberately gated:

1. An unfamiliar request runs as a structured ad-hoc Run.
2. A repeatable successful pattern may become a `draft` capability.
3. Isolated tests, regression comparison, permission review, and owner/admin
   approval are required before `published`.
4. Published objects are versioned rather than silently overwritten and keep a
   rollback path.

The Settings capability index shows lifecycle and embedding freshness and can
refresh source metadata. Refreshing does not bypass the embedding provider or
execute a capability.
