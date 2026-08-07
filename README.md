# Ignatius

Ignatius is the reusable Hara-compatible chain and client platform.

It provides a deterministic, content-addressed state history backed by canonical
Hara values. PostgreSQL is the durable multi-writer adapter; HAL modules provide
the portable transaction and client semantics. Ignatius does not require a
token, public activity feed, or public consensus network.

Ignatius also provides application-neutral process, artifact, signed timeline
and execution-evidence primitives. Hestia builds agent authority, private rooms,
document editing, continuity, negotiation, and product experiences on top of
those primitives. Product-specific protocols and query projections do not live
in this repository.

## Model

```text
HAL client
  -> canonical HCV1/HCP1 transaction
  -> signed Ignatius admission
  -> deterministic execution
  -> transaction, state and block roots
  -> signed receipt
  -> rebuildable application projections
```

Ignatius owns the canonical chain outcome. A consuming application may maintain
ordinary PostgreSQL tables, indexes and caches, but those projections retain
canonical roots and remain rebuildable.

Language-level `defprotocol` and `extend-type` forms lower to closed protocol
intrinsics whose descriptors, dispatchers and implementations become canonical
state. Hara macros remain a pinned compiler-phase facility: transactions retain
the original form root and execute only the signed expanded operation root. See
[`docs/language-protocols.md`](docs/language-protocols.md).

## Runtime demo

The recursive runtime can execute a recognisable Hara-shaped program with a
three-argument function, dynamic lookup and invocation, nested arithmetic,
lexical bindings, branching, strings, vectors, and maps. The checked-in example
is [`examples/agent_score.hal`](examples/agent_score.hal), with its execution and
lowering contract described in [`docs/demo-runtime.md`](docs/demo-runtime.md).

The program deterministically returns:

```clojure
{:winner "alice"
 :message "selected:alice"
 :scores [82 81]
 :spread 1}
```

## Reducer contracts

The primary application contract model is a pure Hara state machine:

```clojure
(defn init [parameters]
  initial-state)

(defn apply-event [state verified-event]
  {:ok next-state})
```

A publisher compiles and signs an immutable template. Parties open instances
pinned to that exact root and interact by submitting signed event maps. Ignatius
derives trusted signer, transaction, time, contract, and previous-head fields,
runs the reducer, and commits a new state and history root only for `{:ok ...}`.

```clojure
(contract/publish module 'contracts/work-order@1)

(def work-order
  (contract/open
    'contracts/work-order@1
    {:buyer alice
     :supplier bob
     :terms terms-root}))

(contract/submit work-order {:action :accept})
(contract/view work-order 'summary)
```

See [`docs/contracts.md`](docs/contracts.md),
[`hal/src/ignatius/contract.hal`](hal/src/ignatius/contract.hal), and
[`examples/work_order_contract.hal`](examples/work_order_contract.hal) for the
compiler, HCV1/HCP1 publication pipeline, signed-event model, and work-order
example.

## Canonical build records

[`ignatius.record`](hal/src/ignatius/record.hal) defines a versioned vocabulary
of ordinary HCV1 values for complete signed builds:

```text
workspace/build
process/definition · process/run · process/step · process/checkpoint
artifact/identity · artifact/version
reference/logical · timeline/entry · workspace/commit-candidate
review/decision · attestation/claim
execution/provenance · ledger/evidence
```

Every record has a pinned envelope:

```clojure
{:record/type :artifact/version
 :record/version 1
 :record/extensions {}
 ...}
```

Stable IDs and exact immutable roots are different fields:

```clojure
{:artifact/id "scene/main"
 :artifact/content-root scene-root-B
 :artifact/previous-content-root scene-root-A
 :artifact/producer-run-id "run/lighting-17"
 :artifact/producer-run-root nil}
```

A stable ID identifies the conceptual scene, document, DOM tree, codebase or run.
A root identifies one exact immutable version. Logical relationships that may be
cyclic use `:reference/logical` values with an optional exact root pin, keeping
the storage graph acyclic.

The repository includes an executable schema catalog and one checked-in
conformance vector for each record family. See
[`docs/canonical-records.md`](docs/canonical-records.md),
[`hal/src/ignatius/record_vectors.hal`](hal/src/ignatius/record_vectors.hal), and
[`hal/test/ignatius/record_test.hal`](hal/test/ignatius/record_test.hal).

## Signed build timelines

[`ignatius.timeline`](hal/src/ignatius/timeline.hal) is a reusable reducer for
tracking a complete build through canonical process runs, immutable artifact
versions, reviews and linked timeline entries.

```clojure
(contract/submit timeline
  {:action :process/start
   :process/id "run/lighting-17"
   :process/definition-root lighting-agent-root
   :process/input-roots [scene-root-A prompt-root]})

(contract/submit timeline
  {:action :artifact/publish
   :artifact/id "scene/main"
   :artifact/content-root scene-root-B
   :artifact/previous-content-root scene-root-A
   :artifact/source-roots [texture-root prompt-root]
   :process/id "run/lighting-17"})
```

The contract state is a canonical `:workspace/build`. Accepted transitions emit
`:process/run`, `:artifact/version`, `:review/decision`, `:timeline/entry` and
`:ledger/evidence` values. Ignatius injects signer, transaction, timestamp,
contract, template and previous-head evidence, while stale artifact updates and
reviews of obsolete roots are rejected.

The current contract keeps one linear authoritative head and uses ordinary HCV1
maps. Multi-parent workspace commits, scalable indexes, structural merges and
portable execution remain separate, compatible phases. Existing timeline
instances remain pinned to their original immutable template and state shape.
See [`docs/build-timelines.md`](docs/build-timelines.md) and
[`docs/process-graph-roadmap.md`](docs/process-graph-roadmap.md).

## Portable storage contracts

[`ignatius.storage`](hal/src/ignatius/storage.hal) separates immutable block
storage, scoped mutable refs and backend capability declarations from any one
provider.

```clojure
(def block
  (storage/hcv1-block
    sha256 type-tag payload-byte-count payload-hex references))

(def stored
  (storage/memory-put-block sha256 backend block))

(def advanced
  (storage/memory-compare-and-set-ref
    (get stored :ok)
    (storage/ref-update-request
      "workspace/orbital-station"
      "main"
      expected-commit-root
      desired-commit-root
      authorization-root)))
```

Every block read is re-hashed before it is returned to a decoder. Exact duplicate
writes are idempotent, while a different envelope under an existing root is a
conflict. Ref writes name an explicit scope, name, expected root, desired root
and authorization root.

The pure memory adapter declares `:single-writer` consistency rather than
pretending to coordinate concurrent hosts. PostgreSQL maps immutable blocks to
the existing `Cell`, ordered `CellRef` and HCP1 snapshot code. The separate
`gwdb.ledger.scoped-ref` adapter provides durable `:linearizable` compare-and-set
for generic workspace, proposal, release and module refs using transaction-scoped
advisory locks and exact-root checks.

The generic ref table does not replace account sequences, contract heads or the
global chain head. Every desired, expected and authorization root must already be
an immutable Ignatius cell, and a stale update returns the accepted root without
discarding candidate commits or blocks.

See [`docs/storage-contracts.md`](docs/storage-contracts.md),
[`hal/test/ignatius/storage_test.hal`](hal/test/ignatius/storage_test.hal), and
[`db/test/gwdb/ledger/scoped_ref_test.clj`](db/test/gwdb/ledger/scoped_ref_test.clj).

## Signed personal workspace branches

The first signed workspace-ref policy lets a verified account advance only its
own `user/<address-root>` branch inside an explicit workspace scope. Ignatius
derives the scope, name and authorization root, validates verified commit
ancestry, performs exact PostgreSQL compare-and-set, and records each successful
selection through the ordinary signed transaction, receipt and linear block
chain. Stale selections do not consume the account sequence or advance the
network head.

Proposal publication and reviewer decisions are separate signed policies.
Shared `main` and release refs are admitted only through explicit selected policy
and evidence roots. See
[`docs/workspace-ref-admission.md`](docs/workspace-ref-admission.md).

## Signed workspace proposals and reviews

A verified account may publish an immutable candidate as
`proposal/<candidate-root>`. The proposal is create-only and cannot be redirected
to a different commit. Reviewers then sign canonical `:review/decision` records
for that exact candidate. Each reviewer has an independent
`review/<candidate-root>/<reviewer-root>` ref updated through exact compare-and-set,
so stale decisions do not consume account sequence or global block height.

Proposal visibility and reviewer statements do not by themselves authorize
`main`. See [`docs/workspace-proposals.md`](docs/workspace-proposals.md) and
[`docs/workspace-reviews.md`](docs/workspace-reviews.md).

## Policy-gated workspace main

[`ignatius.workspace-acceptance`](hal/src/ignatius/workspace_acceptance.hal)
defines the first executable shared-head law. A create-only `policy/main`
attestation pins one authority and an exact ordered reviewer set. An acceptance
attestation then pins the proposed candidate, policy root, current approval
roots, and exact previous `main` root.

V1 requires every listed reviewer to have a current `:approve` decision.
Superseded approvals, rejects, withdrawals, unpublished candidates, non-genesis
bootstrap attempts and non-fast-forward updates are rejected before ref CAS.

PostgreSQL first publishes the immutable policy at `policy/main` through account
sequencing, Ed25519 verification and create-only CAS. A separate signed
acceptance then verifies the selected policy, proposed candidate, exact current
approval roots and commit ancestry before advancing `main`. The transaction
receipt returns the immutable acceptance root while the ref selects the candidate
root; stale main updates consume neither sequence nor block height. See
[`docs/workspace-main-acceptance.md`](docs/workspace-main-acceptance.md),
[`docs/workspace-main-policy-admission.md`](docs/workspace-main-policy-admission.md),
and [`docs/workspace-main-admission.md`](docs/workspace-main-admission.md).

## Immutable workspace releases

[`ignatius.workspace-release`](hal/src/ignatius/workspace_release.hal) publishes
create-only `release/<version>` selections for the candidate currently accepted
at `main`. The canonical release attestation pins workspace, version, candidate,
selected policy and the exact accepted-main evidence root.

PostgreSQL proves that the acceptance has an `ok` receipt bound to a valid block
on the current linear network chain. A structurally valid acceptance created by
a stale main attempt is therefore insufficient. Successful release publication
returns the immutable release claim root while the release ref selects the
candidate; duplicate versions consume neither sequence nor block height. See
[`docs/workspace-release-admission.md`](docs/workspace-release-admission.md).

## Convex-style accounts and actors

New account roots use a backward-compatible v2 shape that separates the external
transaction key from the internal controller. Keyless actor accounts can be
deployed and called through the same recursive evaluator.

The first actor demo deploys a persistent counter and executes:

```clojure
[(call counter increment!)
 (call counter increment!)
 (query counter current)]
;; => [1 2 2]
```

`call` retains the callee's state, while `query` restores the caller's
pre-call state. Callable methods are explicitly marked in account definition
metadata. The canonical `convex.compat` runtime profile maps Convex-shaped source
symbols onto native Ignatius primitives and actor operations.

Actors are an advanced account-composition facility. Ordinary agreements,
workflows, approvals, and document lifecycles should generally use reducer
contracts instead of actor-local mutable-looking state.

See [`docs/convex-actors.md`](docs/convex-actors.md) and
[`examples/counter_actor.hal`](examples/counter_actor.hal).

## Layout

- `db/` — PostgreSQL ledger DSL, generated SQL and generated client contract
- `hal/` — portable codec, runtime, records, storage, transactions and clients
- `examples/` — Hara programs used to drive executable ledger demos
- `extensions/` — optional chain cryptography and proof extensions
- `docs/` — protocol notes, record specifications and integration contracts
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

Run the portable HAL checks:

```sh
make hal-check
make hal-test
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
execution, receipts, integrity verification, snapshots, canonical process and
artifact records, signed reviews, attestations, build-timeline provenance,
workspace commit candidates and provider-neutral storage contracts.

It deliberately excludes:

- agent profiles, mandates and product-specific authority policy;
- private rooms, invitations, membership and negotiation;
- document OT/CRDT algorithms, editor behavior and delivery UX;
- scene, DOM and document merge policy until published as generic modules;
- continuity and recovery ceremonies; and
- product services and user interfaces.

Applications such as Hestia own those experiences and policies while committing
their canonical artifacts, process evidence and accepted lifecycle changes
through Ignatius.

## Provenance

The initial source was filtered with history from `greenways-ai/hestia` at
`62a0cf9c658e9f81c91d3ef16b0f9b3380f0b33c`. See [`MIGRATION.md`](MIGRATION.md)
for the included and excluded source boundaries.

## License

Apache License 2.0.
