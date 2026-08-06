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
