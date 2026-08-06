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

## Signed build timelines

[`ignatius.timeline`](hal/src/ignatius/timeline.hal) is a reusable reducer for
tracking a complete build through signed process runs, immutable artifact
versions and reviews.

```clojure
(contract/submit timeline
  {:action :process/start
   :process/id "lighting-pass-17"
   :process/definition-root lighting-agent-root
   :process/input-roots [scene-root-A prompt-root]})

(contract/submit timeline
  {:action :artifact/publish
   :artifact/id "scene/main"
   :artifact/root scene-root-B
   :artifact/previous-root scene-root-A
   :process/id "lighting-pass-17"})
```

A stable artifact ID identifies the conceptual scene, DOM, document, codebase or
other output. Its content root identifies one exact immutable version. Ignatius
injects signer, transaction, timestamp and previous-head evidence, while stale
artifact updates and reviews of obsolete roots are rejected.

The v1 contract keeps one linear authoritative head and uses existing HCV1 maps.
Multi-parent workspace commits, scalable indexes, structural merges and portable
execution remain separate, compatible phases. See
[`docs/build-timelines.md`](docs/build-timelines.md) and
[`docs/process-graph-roadmap.md`](docs/process-graph-roadmap.md).

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
- `hal/` — portable codec, runtime, transaction and offline-client semantics
- `examples/` — Hara programs used to drive executable ledger demos
- `extensions/` — optional chain cryptography and proof extensions
- `docs/` — protocol notes and integration contracts
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
execution, receipts, integrity verification, snapshots, process runs, stable
artifact/version records, signed reviews and build-timeline provenance.

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
