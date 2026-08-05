# Ignatius

Ignatius is the reusable Hara-compatible chain and client platform.

It owns canonical HCV1/HCP1 values and packs, deterministic Hara
transactions and state, PostgreSQL chain persistence, portable HAL
chain semantics, offline clients, signatures, receipts, snapshots,
and chain extensions.

Hestia builds agent authority, private rooms, documents, continuity,
negotiation, and product experiences on top of Ignatius. Those
application protocols do not live in this repository.

## Layout

- `db/` — PostgreSQL ledger DSL, generated SQL and contracts
- `hal/` — portable chain runtime, transaction and client semantics
- `extensions/` — optional chain cryptography and proof extensions

## Provenance

The initial source was filtered with history from
`greenways-ai/hestia` at `62a0cf9c658e9f81c91d3ef16b0f9b3380f0b33c`.
