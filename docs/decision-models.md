# Decision model

A decision model answers the questions your people answer today: approve or reject, yes or no, how urgent. Allgres uses only the official **laya-serve** (see [decision-records.md](decision-records.md) for the records that train it). It runs outside PostgreSQL, like every model.

Open **Connections → Decision model** (admin).

## Connect a server

1. Run `laya-serve` outside PostgreSQL by its official instructions. If it has a key (`LAYA_API_KEY`), keep it to hand.
2. Enter a name, the server's address, and the key if there is one. Tick the private-network box for a server on this machine or your own network.
3. **Connect and check.** Allgres sends `GET /health` (with the key as a bearer token) and shows:
   - *connected*, with the checkpoints the server has loaded, each one's revision, and its device;
   - *key needed*, when the server answered but only with its status. A server with a key set shows only `{"status":"ok"}` to a caller without the right key;
   - *cannot be reached*, with the reason, when nothing answered or the address does not answer like `laya-serve`.

A server that has just started shows no checkpoint until its first request loads one.

## What connecting does not do

Nothing is handed to the model. Every decision point keeps going to people and rules, whether or not a server is connected, and a person's decisions are recorded in Laya's training format either way. Turning delegation on for a single decision point is a separate step that comes later (stage 6 of [improvement-plan.md](improvement-plan.md)).

## Stored

A connection of kind `decision` (`api_connections`), its key like any other connection key, and what the last check reported (`status_detail`: loaded checkpoints, revisions, devices; never a secret). Dashboard actions: `decision_models.list`, `decision_models.connect`; test and remove use `connections.test` and `connections.delete`.
