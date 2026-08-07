# Portable storage contracts

`ignatius.storage` extracts the storage semantics already present in the
Ignatius ledger into a provider-neutral contract. It does not create a second
canonical database model and it does not change HCV1 roots.

Tracking issue: [#12](https://github.com/greenways-ai/ignatius/issues/12).

## Separation of responsibilities

```text
immutable block store
  stores exact bytes under a verified content root

scoped ref store
  maps an explicit scope and name to one current immutable root

backend capabilities
  state the consistency, durability and verification guarantees

Ignatius admission
  verifies signatures, authority, account ordering and accepted global state
```

The VM and portable clients depend on the contracts. PostgreSQL, SQLite,
IndexedDB, Git, object storage and memory adapters can implement them without
changing semantic code.

## Why this is not a new ledger

The PostgreSQL ledger already has the authoritative immutable block substrate:

- `Cell` stores one HCV1 payload under its SHA-256 root;
- update and delete triggers make cells immutable;
- `cell-put` verifies the root and makes exact duplicate writes idempotent;
- `CellRef` stores ordered labelled child links;
- `cell-ref-entries` reconstructs those links deterministically; and
- HCP1 snapshots walk, pack and import the reachable cell graph.

The portable contract names those behaviours so execution code no longer needs
to know that the implementation is PostgreSQL. It does not rename the tables,
move canonical state out of the ledger, or reinterpret historical roots.

## Interface descriptors

The portable module publishes three versioned descriptors:

```clojure
ignatius.storage/block-store-interface
ignatius.storage/ref-store-interface
ignatius.storage/backend-capabilities-interface
```

They describe the required calls without assuming a host object model:

```clojure
:get-block
  [:backend :root :sha256]
  -> verified block or error

:put-block
  [:backend :block :sha256]
  -> updated backend or error

:get-ref
  [:backend :ref-read-request]
  -> scoped ref value or error

:compare-and-set-ref
  [:backend :ref-update-request]
  -> updated backend or exact-root conflict
```

A Hara host may expose these through protocols, capability functions, RPC tools
or direct module calls. The semantic contract is the same.

## Block envelope

The first supported block codec is the existing HCV1 codec:

```clojure
{:block/root root
 :block/codec :hara/hcv1
 :block/codec-version 1
 :block/hash-algorithm :sha-256
 :block/type-tag type-tag
 :block/payload-byte-count byte-count
 :block/payload-hex payload-hex
 :block/references
 [{:position 0
   :role "child"
   :child-root child-root}]}
```

The root remains:

```text
SHA-256(UTF8("HCV1:" + type-tag + ":" + byte-count + ":" + payload-hex))
```

`:block/references` are derived traversal metadata. The HCV1 payload commits the
child roots according to the value type; an adapter must not treat unverified
reference rows as independent semantic truth.

## Explicit cryptography

Block verification never relies on an ambient hash implementation. The caller
supplies an explicit SHA-256 capability:

```clojure
(storage/hcv1-block
  sha256 type-tag byte-count payload-hex references)

(storage/verify-block sha256 fetched-block)
```

Both `memory-put-block` and `memory-get-block` call `verify-block`. A fetched
block is re-hashed before it is returned to any decoder.

This means the safe load sequence is:

```text
provider bytes
  -> reconstruct block envelope
  -> verify codec and hash algorithm
  -> recompute root
  -> compare with requested root
  -> only then decode HCV1
```

A cache may retain verified decoded values, but cache keys remain exact roots.

## Immutable writes

```clojure
(storage/memory-put-block sha256 backend block)
```

The operation has three outcomes:

```clojure
{:ok updated-backend
 :block/value block
 :block/created true}
```

```clojure
{:ok unchanged-backend
 :block/value block
 :block/created false}
```

```clojure
{:error :storage/block-conflict
 :block/root root
 :block/existing existing
 :block/proposed proposed}
```

An exact duplicate is idempotent. A different envelope under an existing root is
always a conflict, even if a defective or test hash capability reports the same
root for both inputs.

## Scoped refs

A mutable ref is not a content-addressed value. It is a small, explicit pointer
used to select an accepted immutable root:

```clojure
{:ref/scope "workspace/orbital-station"
 :ref/name "main"
 :ref/root workspace-commit-root}
```

Scopes prevent unrelated applications and workspaces from sharing an ambient
name table. Names can represent:

```text
main
user/alice
proposal/52
release/1.0.0
module/scene-tools/stable
```

Reads and writes carry an explicit authorization root:

```clojure
(storage/ref-read-request
  "workspace/orbital-station"
  "main"
  authority-root)
```

```clojure
(storage/ref-update-request
  "workspace/orbital-station"
  "main"
  expected-root
  desired-root
  authority-root)
```

The storage adapter requires the authorization context but does not invent
product authority policy. Ignatius admission, Hestia mandates, workspace rules
or another explicit policy module decide whether the supplied authority permits
the update.

## Compare-and-set

```clojure
(storage/memory-compare-and-set-ref backend request)
```

Creation uses an expected root of `nil`:

```clojure
nil -> commit-A
```

Advancement names the exact accepted root:

```clojure
commit-A -> commit-B
```

A stale writer receives the actual current root:

```clojure
{:error :storage/ref-conflict
 :ref/scope "workspace/orbital-station"
 :ref/name "main"
 :ref/expected-root "commit-A"
 :ref/actual-root "commit-B"
 :ref/desired-root "commit-C"}
```

Candidate blocks and commits remain immutable and retrievable after a stale ref
update. A caller may rebase, propose a branch, or run a merge policy rather than
losing work.

A desired root of `nil` is rejected. Deletion must be a separate, explicit
operation with its own retention and authorization rules; it is not an accidental
form of compare-and-set.

## Capability declarations

Every backend exposes a capability map. The pure in-memory conformance adapter
reports:

```clojure
{:backend/type :memory
 :backend/name "test-memory"
 :backend/durability :process
 :block/immutable true
 :block/verification :required
 :block/hash-algorithm :sha-256
 :ref/compare-and-set true
 :ref/consistency :single-writer
 :ref/authorization :explicit}
```

Allowed ref consistency declarations are:

- `:linearizable` — concurrent successful updates have one authoritative order;
- `:single-writer` — safe only when one writer owns and threads backend state;
- `:advisory` — races may be observed and the ref cannot be used as an
  authoritative acceptance boundary.

The in-memory adapter deliberately declares `:single-writer`. A pure state value
is deterministic, but it does not itself coordinate concurrent host threads.

## In-memory conformance adapter

`memory-backend` is an ordinary Hara value:

```clojure
{:storage/backend-type :memory
 :storage/backend-name "test-memory"
 :storage/blocks {}
 :storage/refs {}
 :storage/capabilities {...}}
```

All operations return a successor value rather than mutating ambient process
state. This makes it suitable for:

- portable conformance tests;
- offline simulations;
- reducer and VM unit tests;
- deterministic examples; and
- reference behaviour for future adapters.

The adapter covers:

- insert, idempotent reinsert and immutable conflicts;
- missing and corrupt block reads;
- read-time rehashing;
- scoped ref reads;
- create and advance compare-and-set;
- stale-head conflicts;
- independent names and scopes; and
- explicit capability declarations.

## PostgreSQL block-store mapping

The PostgreSQL adapter maps directly onto the current ledger:

| Portable contract | Existing PostgreSQL implementation |
| --- | --- |
| block root | `Cell.hash` |
| codec version | `Cell.codec_version` |
| HCV1 type tag | `Cell.type_tag` |
| payload bytes | `Cell.payload` |
| payload byte count | `Cell.byte_size` |
| ordered child references | `CellRef` |
| get block | `cell-by-hash` plus `cell-ref-entries` |
| verify block | `cell-valid` / `codec/verify`, followed by portable re-verification at trust boundaries |
| put block | `cell-put` followed by validated `cell-ref-put` calls |
| graph export/import | HCP1 snapshot pack and import functions |

The authoritative database continues to reject updates and deletes of committed
cells. No new block table is required.

A PostgreSQL read adapter should reconstruct the portable envelope from the cell
and ordered refs, convert bytea roots and payloads to the agreed portable hex
form, and invoke `verify-block` before decoding outside the database.

## PostgreSQL scoped refs

Ignatius already uses exact-head checks in several specialised places:

- account transaction sequences;
- contract expected-head transitions;
- global block/state advancement; and
- immutable publication aliases pinned through account state.

Those mechanisms remain authoritative and unchanged. They are not silently
relabelled as a generic ref table.

The next #12 slice adds an isolated PostgreSQL scoped-ref adapter with atomic
compare-and-set semantics. It will:

- use explicit scope and name columns;
- store only exact immutable roots;
- declare `:linearizable` consistency;
- require verified authorization/admission context at the call boundary;
- preserve stale candidate commits and blocks; and
- avoid renaming or replacing existing chain, account or contract heads.

Keeping this as a separate PR makes the storage seam reviewable and prevents a
portable interface change from being coupled to an SQL migration.

## Other providers

### SQLite

Use an immutable block table and transactional scoped-ref rows. Ref consistency
is linearizable within the SQLite writer transaction model, subject to the
adapter's documented process and filesystem constraints.

### IndexedDB

Store blocks by root and refs by `[scope, name]`. The adapter must state whether
its transaction pattern provides linearizable or only single-writer semantics.

### Object storage plus PostgreSQL

Store immutable payloads in R2/S3 and authoritative refs in PostgreSQL. Object
reads are always re-hashed because object-store metadata is not semantic proof.

### Git

Git objects can carry packs or exported blocks, while named branches or files
act as refs. The adapter must not claim linearizable multi-writer CAS unless the
hosting service and update API genuinely provide it.

## Non-goals of this slice

- changing HCV1 or HCP1;
- moving the VM into PostgreSQL or object storage;
- replacing current account, contract or chain heads;
- introducing HPT1;
- implementing garbage collection;
- defining Hestia authority policy; or
- making the global Ignatius ledger branchable.
