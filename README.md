# Ignatius

Ignatius is the reusable Hara-compatible chain and client platform.

It provides a deterministic, content-addressed state history backed by canonical
Hara values. PostgreSQL is the durable multi-writer adapter; HAL modules provide
the portable transaction and client semantics. Ignatius does not require a
token, public activity feed, or public consensus network.

Hestia builds agent authority, private rooms, documents, continuity,
negotiation, and product experiences on top of Ignatius. Those application
protocols and their query projections do not live in this repository.

## Model

```text
HAL client
  -> canonical HCV1/HCP1 transaction
  -> signed Ignatius admission
  -> deterministic execution
  -> transaction, state and block roots
  -> signed receipt
  -> application-owned projections
```

Ignatius owns the canonical chain outcome. A consuming application may maintain
ordinary PostgreSQL tables, indexes and caches, but those projections retain
canonical roots and remain rebuildable.

## Layout

- `db/` — PostgreSQL ledger DSL, generated SQL and generated client contract
- `hal/` — portable codec, runtime, transaction and offline-client semantics
- `extensions/` — optional chain cryptography and proof extensions
- `versions.edn` — immutable upstream source revisions used by the build

## Set up

The build uses pinned Hara and Foundation source checkouts:

```sh
make setup
```

This materializes ignored local checkouts beneath `.local/` and `db/checkouts/`.
The revisions are recorded in `versions.edn`.

Generate and verify the PostgreSQL artefacts:

```sh
make db-sql
make db-contracts
```

Run the SHA extension test:

```sh
make extension-sha-test
```

The complete reproducibility check is:

```sh
make verify
```

CI also rejects Hestia application namespaces from entering the Ignatius source,
generated SQL, or generated contracts.

## Application boundary

Ignatius includes generic controller registration, signed transaction admission,
execution, receipts, integrity verification and snapshots.

It deliberately excludes:

- agent profiles, mandates and application authority;
- private rooms, invitations, membership and negotiation;
- document OT, provenance, approvals and delivery;
- continuity and recovery ceremonies; and
- product services and user interfaces.

Those belong to applications such as Hestia and commit their canonical records
through Ignatius.

## Provenance

The initial source was filtered with history from `greenways-ai/hestia` at
`62a0cf9c658e9f81c91d3ef16b0f9b3380f0b33c`. See [`MIGRATION.md`](MIGRATION.md)
for the included and excluded source boundaries.

## License

Apache License 2.0.
