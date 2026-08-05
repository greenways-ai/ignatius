# Ignatius PostgreSQL adapter

`db/` is the durable multi-writer PostgreSQL implementation of the Ignatius
Hara chain. It owns canonical chain storage and execution; it does not define
Hestia agents, rooms, documents, recovery ceremonies, or product projections.

## Responsibilities

The adapter provides:

- HCV1 canonical cells and child references;
- accounts, controller keys, state roots, operations, functions, modules and
  iterators;
- deterministic operation execution and cost accounting;
- signed transaction admission and atomic block commitment;
- transaction and block receipts;
- HCP1 snapshot export/import and integrity verification; and
- generated SQL and a generated TypeScript client contract.

PostgreSQL is an Ignatius adapter, not the protocol definition. Portable chain
framing and client transitions live in `../hal/`. Hestia may add ordinary tables
and projections beside an Ignatius database, but application rows must retain
canonical roots and remain rebuildable from admitted records and receipts.

## Generate artefacts

The build uses a sibling Foundation checkout at `checkouts/foundation`:

```sh
git clone https://github.com/zcaudate-xyz/foundation-base.git \
  db/checkouts/foundation

cd db
lein sql
lein contracts
```

Generated outputs are committed:

- `sql/full.sql`
- `contracts/ledger-client/generated.ts`

CI regenerates both and rejects drift.

## Focused tests

Start the repository REPL, enter a test namespace and run it with the Foundation
test runner, for example:

```clojure
(code.test/run '[gwdb.ledger.integrity-test])
```

JDBC tests require a local PostgreSQL image. Signed-ledger tests use the pinned
PostgreSQL 15 image with `pgsodium`:

```sh
docker build -t ignatius-postgres:15-pgsodium \
  -f db/Dockerfile.postgres15-pgsodium db
```

## Admission boundary

Clients retain private Ed25519 keys. PostgreSQL receives public keys, canonical
signing bytes, detached signatures and bounded canonical packs. The generic
admission surface supports controller registration and signed Hara transactions.
Application admission—for example Hestia profile, room or document records—lives
in the consuming application and commits through Ignatius rather than being
compiled into this adapter.

## Namespaces

The initial extraction retains the internal `gwdb.ledger.*` Clojure namespaces
to preserve generated SQL and compatibility while the public package becomes
Ignatius. Portable HAL modules use `ignatius.*` immediately. Internal namespace
renaming can happen later as a mechanical release migration; it must not change
canonical bytes or historical roots.

## Provenance

This adapter was extracted with filtered Git history from
`greenways-ai/hestia`. See [`../MIGRATION.md`](../MIGRATION.md).
