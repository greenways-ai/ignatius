# `gwdb.ledger.*`

This is the standalone PostgreSQL DSL project for the Hara ledger. It uses a
local Foundation checkout but does not load Supabase adapters or application
schemas.

The current scaffold contains the foundational schema and protocol-facing
descriptors:

- stable numeric Hara value tags and codec version metadata;
- a documented Hara Canonical Value Encoding v1 payload boundary and SHA-256
  prototype hash helpers over explicit `bytea` payloads;
- `gw_ledger.Cell`, an idempotent content-addressed cell table;
- `gw_ledger.CellRef`, a derived composite-key child-reference table;
- explicit syntax, state, account, operation, context, primitive, function,
  module, iterator, transaction, block, and snapshot projections;
- a canonical operation VM for constant, local, lookup, invoke, lambda, do,
  cond, let, def, and explicit context-special values, with deterministic
  cost accounting and closed primitive dispatch;
- persistent function values, lexical-frame execution, canonical module
  publication/export resolution, and serialisable vector iterator plans;
- closed transaction-envelope validation, deterministic cost-limit checks,
  sequence consumption, receipts, and row-locked head advancement;
- one-transaction execution with sequence consumption, receipts, and an
  ordered transaction link in an atomic block commit path;
- integrity checks plus targeted account and module-export projection rebuilds
  derived from canonical roots;
- deterministic HCP1 snapshot packs containing every reachable cell and ordered
  `CellRef` envelope, with two-pass cell/reference import and pack/count
  verification at creation and read time;
- emitter tests that inspect generated PostgreSQL rather than hand-written SQL.
- Ed25519 controller-key validation via the pinned `pgsodium` PostgreSQL
  extension. Signing bytes are canonical, domain-separated transaction fields;
  the detached signature is deliberately excluded from them.

The remaining major work is a complete compiler-facing operation validator,
full iterator transformations, multi-transaction block replay, parsing an HCP1
pack into a separately provisioned clean database test, and complete projection
rebuild/repair coverage.
The current payload constructors accept already-canonical `bytea` components
so the database does not silently invent a host-language encoding.

The DSL's `:time` type emits the repository-standard deterministic `BIGINT`
microsecond representation, so `created_at` intentionally follows the existing
Greenways convention rather than introducing an unsupported PostgreSQL type.

From the repository root:

```bash
make ledger-check
make ledger-scaffold
make ledger-sql
make ledger-contracts
```

Use the repository REPL test runner for focused development. Start the local
REPL, change into the relevant test namespace, then evaluate:

```clojure
(code.test/run '[gwdb.ledger.integrity-test])
```

The JDBC tests use the standard `lib.postgres` temporary-container runtime and
therefore require a locally available PostgreSQL image.

Signed-ledger tests additionally require the local, pinned PostgreSQL 15 image:

```bash
docker build -t gw-ledger-postgres:15-pgsodium \
  -f Dockerfile.postgres15-pgsodium .
```

The image extends the ordinary `postgres:15` test image with pgsodium only; it
does not introduce a Supabase service or runtime dependency. Browser wallets
hold private Ed25519 keys locally and submit detached signatures. PostgreSQL
receives only the public controller key, the canonical signing bytes, and the
signature.

## Unsigned developer console

The development console is a deliberately separate, unsigned admission
surface. It creates a genesis block, creates development accounts, and commits
integer-constant transactions through the durable `gw_ledger.developer_*`
functions. It must not be enabled for a production or signed-ledger network.

Generate the database definition and the browser contract from the ledger
sources:

```bash
lein sql
lein contracts
```

The canonical browser contract is generated at
`contracts/ledger-client/generated.ts`. The `greenways-ai/v2` repository owns
the consuming Next application and explicitly synchronizes this file into its
ledger-client package.

Load `sql/full.sql` into a PostgreSQL 15 database that has the pgsodium
extension available, then start the v2 application with a server-only
connection string:

```bash
cd "$V2_DIR/main/js"
LEDGER_DATABASE_URL=postgres://postgres:postgres@localhost:5432/gw-ledger \
  corepack yarn workspace @statstrade/ledger dev
```

The console is served at its Next application root. Its browser client uses
the generated `@statstrade/ledger-client` contract; only the server route owns
`LEDGER_DATABASE_URL`. The route calls the controlled developer functions with
parameterised arguments, never exposes database credentials to the browser,
and displays the resulting immutable transaction, receipt, block, and state
roots.

## Signed controller admission

The default console creates an Ed25519 keypair with WebCrypto and keeps the
private key in the browser's IndexedDB wallet. Account registration signs a
domain-separated registration payload. Transaction submission first requests
the database's canonical signing payload, signs it locally, then sends the
public key and detached signature to the admission functions. PostgreSQL
verifies the signature against the controller committed in the predecessor
state before it executes or commits the transaction.

The unsigned endpoints remain available only for local bootstrap when both
the server and browser opt in explicitly:

```bash
LEDGER_ENABLE_UNSAFE_DEVELOPER_API=true \
NEXT_PUBLIC_LEDGER_ENABLE_UNSAFE_DEVELOPER_API=true \
LEDGER_DATABASE_URL=postgres://postgres:postgres@localhost:5432/gw-ledger \
  corepack yarn workspace @statstrade/ledger dev
```

Do not set either variable in a deployed signed-admission environment. Its
genesis state must be provisioned outside the browser console.

## Offline Hara REPL v2

The browser REPL parses a bounded Hara form, constructs semantic form and
canonical operation cells, executes it locally, signs the exact transaction
payload, and queues the transaction before any network request. Runtime v1
supports literals, quote, two-argument `+` and `*`, one-binding `let`, `if`,
and `do`; `:head` and `:register` remain console commands.

## CLI

The Node CLI speaks to the public developer HTTP API and stores its own
Ed25519 private key locally (default `.gw-ledger/controller.pem`, mode 0600).
It never receives or needs a database connection string.

```bash
cd main/js
LEDGER_URL=http://127.0.0.1:3000 \
LEDGER_NETWORK=devnet \
corepack yarn workspace @statstrade/ledger cli register

corepack yarn workspace @statstrade/ledger cli eval 7
corepack yarn workspace @statstrade/ledger cli head
corepack yarn workspace @statstrade/ledger cli repl
```

`genesis` is available only when the server enables the unsafe local developer
API. The CLI REPL accepts the same v1 forms as the browser console.

## Offline signed documents

The browser can create and replace syntax-text documents without a network
connection. It builds canonical HCV1 cells, an HCP1 pack, and the exact
document signing payload locally; the Ed25519 private key remains in IndexedDB.
Pending operations stay in the IndexedDB outbox until **Sync outbox** is used.

The server imports the pack and verifies the signature in one PostgreSQL
statement. Invalid signatures, root mismatches, and malformed packs roll the
statement back. Public admission currently limits a pack to 128 cells and
1,000,000 hexadecimal characters.

Portable framing and outbox semantics live in the sibling
`gwdb-ledger-hal/` component:

```bash
make ledger-hal-test
```

Browser/PostgreSQL end-to-end targets remain in `greenways-ai/v2`, which owns
the browser application:

```bash
make ledger-e2e-offline
```

The IndexedDB database contains separate content-addressed `cells`, signed
`outbox`, and accepted `receipts` stores. A synchronized transaction retains
its transaction, receipt, result, state, block, and cost data. Sequence and
document-head conflicts remain in the outbox with a visible conflict status.

General transaction admission imports the HCP1 pack, rebuilds and verifies
every closed primitive and operation projection, verifies the Ed25519
signature, executes the operation, and commits its receipt and block in one
PostgreSQL transaction.

Run the local evaluator/PostgreSQL parity and replay-conflict test against a
running console:

```bash
make ledger-e2e-hara
```

Offline document authoring currently supports syntax-wrapped text creation and
replacement. List/vector insert, delete, and move authoring remain later UI
work.

Extracted from `greenways-ai/v2` at
`045660a34b46556fe10e7cab783e4a34756f83bd`.
