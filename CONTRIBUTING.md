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

## Claude Code sessions

`.claude/settings.json` sets up three tools that cut the tokens a Claude Code
session spends while developing:

- **rtk** (Apache-2.0 `rtk-oss` edition) condenses Bash command output such
  as `git`, `cargo`, `ls`, and `grep`. Run `rtk bypass <cmd>` when the full
  output is needed.
- **graphify** builds a code knowledge graph in `graphify-out/` (ignored by
  Git, AST only, no model calls). Ask it with `graphify query "<question>"`
  before reading raw source, and refresh it with `graphify update .`.
- **caveman** (vendored skill in `.claude/skills/caveman/`, MIT) keeps replies
  terse. Say "stop caveman" or "normal mode" to turn it off for a session.

In cloud sessions `.claude/hooks/session-start.sh` installs pinned versions of
rtk and graphify and builds the graph. On a local machine the hooks do nothing
until you install `rtk` and `graphifyy[sql]` yourself; the caveman skill works
either way.
