# Configuration

Part of the [documentation index](../README.md). See also:
[Security](security.md) for what several of these actually gate.

| Variable | Default | Meaning |
| --- | --- | --- |
| `ALLGRES_DATABASE` | `postgres` | Database the runtime worker attaches to |
| `ALLGRES_HTTP_ADDR` | `127.0.0.1:8088` | Dashboard listen address |
| `ALLGRES_DASHBOARD_TOKEN` | empty | Bearer token for `/api/v1/*` |
| `ALLGRES_ALLOW_INSECURE_HTTP` | unset | Permit a public bind with no token |
| `ALLGRES_ALLOWED_HOSTS` | unset | Comma-separated host names the dashboard answers to, in addition to `localhost`, the bind host, and any IP literal (`name` or `name:port`). Unset with no token: only those defaults; unset with a token: no Host check. Set it to turn the check on with a token too; `*` turns it off. See [Security](security.md#dns-rebinding) |
| `ALLGRES_SOCKET_DIR` | `$PGDATA/allgres` | RPC socket directory |
| `ALLGRES_SECRET_KEY` | empty | Encrypts provider secrets at rest |
| `ALLGRES_ENABLE_MOCK` | unset | Serve `/mock/models`, `/mock/chat/completions`, `/mock/embeddings`, and `/mock/oauth/token` (tests and local first-run) |
| `ALLGRES_RATE_LIMIT_PER_MINUTE` | `120` | Requests per minute per client address before `rate_limited`. Raise only when many clients really share one address (a browser test run, a proxy that hides client addresses) |
| `ALLGRES_DROP_PRIVILEGES` | `1` | Runtime worker drops to the `allgres_worker` role |
