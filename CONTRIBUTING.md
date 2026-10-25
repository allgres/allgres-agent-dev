# Contributing

Allgres is a Rust/pgrx PostgreSQL extension whose core state machine is
implemented in `sql/`, with native workers in `src/` and the dashboard in
`web/`.

## Development checks

Before opening a pull request:

1. Build and install with the PostgreSQL version you changed:
   `cargo pgrx install --no-default-features --features pgNN --pg-config <path>`.
2. Create the extension in a fresh database and confirm
   `allgres_public.fn_selftest()` reports zero failures.
3. Run the self-test again from a separate connection to verify idempotency.
4. Run `cargo test --lib` and the relevant SQL or HTTP integration tests.

Changes to `dashboard_rpc` must also update `sql/rpc_catalog.json` with
`python3 scripts/gen_rpc_catalog.py`. Security-sensitive SQL functions should
use the narrowest possible owner and privilege set; do not broaden
`allgres_owner` to make a test pass.

Keep comments focused on non-obvious constraints and invariants. Update the
relevant document under `docs/` whenever behavior changes.
