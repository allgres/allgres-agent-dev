# Inbound events

An outside system, such as a sensor, a monitoring tool, or a form, can hand work to an agent. It sends a signed POST to Allgres. Open **Connections → Inbound events** (admin).

## Set up a source

1. Enter a name (letters, digits, `-`, `_`), pick the agent that handles it, and write what to ask it. Put `{{event}}` where the event goes. System agents are not allowed.
2. Choose what happens when an event arrives:
   - **Hold for a person** (default). The event waits on this page and on Home until someone presses **Start a task** or **Dismiss**.
   - **Start a task by itself.** A task for the agent starts at once.
3. Copy the secret that appears. It is shown once and stored encrypted. **New secret** replaces it and the old one stops working at once.

## Send an event

```bash
BODY='{"sensor":"pump-3","temp":91}'
TS=$(date +%s)
SIG=$(printf '%s.%s' "$TS" "$BODY" | openssl dgst -sha256 -hmac "$SECRET" -hex | sed 's/^.* //')
curl -X POST https://allgres.example.com/inbound/pump-alerts \
  -H "X-Allgres-Timestamp: $TS" \
  -H "X-Allgres-Signature: sha256=$SIG" \
  -H "X-Allgres-Event-Id: pump-3-2026-10-26T14:00" \
  -d "$BODY"
```

- The signature is HMAC-SHA256 over `timestamp + "." + body` with the source's secret. The timestamp must be within five minutes of Allgres' clock.
- `X-Allgres-Event-Id` is optional. Sending the same id again is answered `200` with `duplicate: true` and does nothing, so a retry is safe.
- Answers: `202` accepted, `200` duplicate, `401` not accepted (an unknown source, a disabled source, a bad signature, and an old timestamp all look the same), `413` over 64 KB, `429` too many events (per source, 30 a minute by default; and a caller that keeps failing is locked out for a while).

## What the agent sees

The goal you wrote, with the event placed inside a marked block that says it is data and not instructions. It is cut to 4000 characters. Nothing in an event can run, grant permission, or change the goal. The agent still works under its own permissions, approvals and budgets.

## Reaching Allgres from outside

The dashboard listens on a local address by default. To receive events from other machines, put a reverse proxy you trust in front of it and forward only `/inbound/` if you can. The signature protects the request, not the connection: use https.

## Checks that run on a timer

Every 15 minutes Allgres checks each enabled MCP server (a tool discovery, which also notices tools that changed) and each decision model (`/health`). A server that needs a sign-in and was never signed in to is left alone. Plain API connections are checked only when you press **Test**. A connection that is not healthy appears under **Needs attention** on Home.

## Stored

`inbound_sources` (the secret is encrypted and never listed) and `inbound_events`. Dashboard actions: `inbound.sources`, `inbound.source_create`, `inbound.source_rotate`, `inbound.source_set`, `inbound.source_delete`, `inbound.events`, `inbound.event_start`, and `inbound.receive` (no session; the signature authorizes it).
