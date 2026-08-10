# Ignatius PostgreSQL chain

`db/` is the durable multi-writer PostgreSQL implementation of the Ignatius
Hara chain. It owns canonical chain storage and execution; it does not define
Hestia agents, rooms, documents, recovery ceremonies, or product projections.

## Responsibilities

The chain provides:

- HCV1 canonical cells and child references;
- accounts, controller keys, state roots, operations, functions, modules and
  iterators;
- deterministic operation execution and cost accounting;
- signed transaction admission and atomic block commitment;
- transaction and block receipts;
- HCP1 snapshot export/import and integrity verification; and
- generated SQL and a generated TypeScript client contract.

PostgreSQL is the authoritative Ignatius chain. Portable transaction framing,
local evaluation, signing, submission and receipt verification live in
`../hal/` as its client. Those modules must conform to PostgreSQL execution and
must not replace it. Hestia may add ordinary tables and projections beside an
Ignatius database, but application rows must retain canonical roots and remain
rebuildable from admitted records and receipts.

`sql/full.sql` is a destructive fresh-install baseline. It must never be run
against an existing node. Existing nodes advance only through the ordered,
non-destructive migrations described in `migrations/README.md`.

Plan or apply those migrations with:

```sh
scripts/ignatius-chain-migrate --plan
scripts/ignatius-chain-migrate "$DATABASE_URL"
```

The runner verifies contiguous versions and exact SHA-256 digests, rejects
newer or protocol-incompatible nodes, holds a PostgreSQL transaction advisory
lock, and applies each migration atomically. Build the deterministic installable
archive and its checksum and metadata with `scripts/build-chain-release`.

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

## PostgreSQL-target HAL source

Every namespace under `src/gwdb/ledger` has a PostgreSQL-target `.hal` shadow
beside its Foundation `.clj` migration source. The namespace names, DSL forms,
schema names and canonical algorithms are intentionally unchanged. The only
bootstrap difference is that HAL sources require `lang.core` rather than the
legacy `tahto.core` façade.

The HAL project entry point is `gwdb.ledger.base`, so it closes over the entire
chain implementation rather than only the portable client:

```sh
make db-hal-parity
make db-hal-check
make db-hal-test
```

`db-hal-parity` is part of `make verify`. It requires a one-for-one source map
and byte-for-byte equality after normalising the bootstrap require and the
small closed set of HAL API translations (`defonce`, macro-only script setup,
runtime lifecycle names and the `code.test` result bridge). During the shadow
period, change the `.clj` form through the Foundation REPL-first workflow and
make the corresponding evaluated `.hal` change in the same commit.

`db-hal-test` grants PostgreSQL and process access because the test runtime uses
`std.db.postgres` for its connection and `lib.docker` to manage the disposable
database fixture. Hara registers that provider as `[:postgres :db.client]`;
there is no JDBC runtime or vendor selector in the HAL path. Source loading and
complete PostgreSQL emission do not require the provider, while executing
`!.pg` integration facts does. The `.clj` copies may be removed only after HAL
emission matches the committed SQL and that provider-backed integration suite
passes from the HAL entry point.

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

This chain implementation was extracted with filtered Git history from
`greenways-ai/hestia`. See [`../MIGRATION.md`](../MIGRATION.md).
