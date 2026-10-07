# Changelog

All notable changes will be documented here.

## Unreleased

## 0.1.0-alpha.3

- Built-in mock now answers `GET /mock/models` (and `/mock/v1/models`) so Settings → Test connection works against the same endpoint bootstrap uses for a first chat.
- Dashboard onboarding marks step 3 complete after General has finished a turn, not only after a model is saved.
- Provider probe errors prefer a JSON `error` field over the raw response body, so a 404 is `not_found` rather than `{"ok":false,"error":"not_found"}`.
- Creating a regular user assigns the seeded `general` agent so Chat works on first login without an extra Users-page click.
- Dashboard folds `health_monitor` with System agents so the main Agents list is conversation agents, not the seeded maintenance example.

## 0.1.0-alpha.2

- Onboarding checklist, Chat General as a 1:1 conversation, selftest isolation, and first-run draft/project guards.

## 0.1.0-alpha.1

- First public alpha.
- PostgreSQL-native agent control plane with Rust/pgrx runtime and web workers.
- PostgreSQL 16, 17, and 18 support.
- Docker and CloudNativePG extension images for amd64 and arm64.
