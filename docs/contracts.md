# Reducer contracts

Ignatius contracts are immutable Hara state machines. A contract template defines
two required pure functions:

```clojure
(defn init [parameters]
  initial-state)

(defn apply-event [state verified-event]
  {:ok next-state}
  ;; or
  {:error error-value})
```

Views are optional one-argument pure functions over contract state.

This is the normal application contract model. Convex-style keyless actor accounts
remain available as an advanced execution facility, but contract authors do not
need actor-local globals, callable metadata, remote methods, or mutable-looking
storage.

## Template, publication, and instance

These are separate objects:

```text
Hara source
    ↓ compile
immutable template root
    ↓ publisher-signed publication
publisher alias → exact template root
    ↓ open
contract instance with its own state and event history
```

A **template** is reusable code and metadata. A **publication** proves that one
account published an exact template root. An **instance** is a particular
agreement pinned to that root.

A publisher cannot modify an existing template. It can publish a new template
root and move a human-facing alias, but existing instances remain pinned to the
root under which they were opened.

## Canonical template

The compiler emits a descriptor equivalent to:

```clojure
{:record/type :contract/template
 :contract/name 'contracts.work-order
 :contract/version "1.0.0"
 :contract/publisher publisher-address

 :contract/init init-function-root
 :contract/transition apply-event-function-root
 :contract/views
 {'summary summary-function-root}

 :contract/source source-root
 :contract/compiler compiler-root
 :contract/runtime runtime-root

 :contract/event-schema event-schema-root
 :contract/state-schema state-schema-root}
```

Ignatius validates that:

- `init` is a persistent function with arity one;
- `apply-event` is a persistent function with arity two;
- every view is a persistent function with arity one;
- source, compiler, runtime, and schema roots exist;
- the runtime root names a supported immutable runtime profile; and
- the template publisher matches the verified account publishing it.

The descriptor is an ordinary canonical HCV0 map, so its content root is the
template identity.

## How a contract is compiled

Compilation occurs before ledger admission:

```text
1. Read Hara source.
2. Macroexpand with a pinned compiler and pinned macro/module roots.
3. Analyse names, locals, arities, and deterministic effects.
4. Lower `init`, `apply-event`, and views to Ignatius operation graphs.
5. Commit persistent function roots for those graphs.
6. Encode source, schemas, functions, and descriptor as HCV0 cells.
7. Pack the complete reachable graph into an HCP0 bundle.
8. Produce the template root and publication operation.
```

The transaction retains or references:

```clojure
{:source-root source-root
 :compiler-root compiler-root
 :runtime-root runtime-root
 :template-root template-root}
```

PostgreSQL does not parse source or execute macros. It imports the canonical cell
pack, rebuilds disposable operation/function projections, verifies all roots and
arities, and executes only the signed canonical operation.

The initial implementation prevents reducer code from committing ambient account
state by restoring the execution state after `init`, transitions, and views. A
future compiler effect pass can reject stateful operations before publication as
well.

## How a contract is published

Any externally controlled Ignatius account may publish a template:

```clojure
(contract/publish
  'ignatius.examples.work-order-contract
  'contracts/work-order@1)
```

At the operation level this is:

```clojure
(contract/publish-op
  template-operation
  alias-operation)
```

The publication path is:

```text
publisher client
    ├── HCP0 template pack
    ├── exact template root
    ├── publisher-local alias
    └── signed Ignatius transaction
              ↓
Ignatius admission
    ├── verifies the account signature
    ├── imports and validates cells
    ├── verifies template.publisher == transaction origin
    ├── binds alias → exact template root
    └── returns a contract-publication root
```

The publication record commits:

```clojure
{:record/type :contract/publication
 :contract/template template-root
 :contract/publisher publisher
 :contract/alias 'contracts/work-order@1
 :contract/transaction transaction-root
 :contract/timestamp ledger-timestamp}
```

Aliases are conveniences and may move. Security-sensitive clients pin the
template root. Registries may layer accreditation, audits, documentation, and
version discovery over publication roots without changing the template.

## Opening an instance

A party opens an instance with parameters:

```clojure
(def work-order
  (contract/open
    'contracts/work-order@1
    {:buyer alice
     :supplier bob
     :terms terms-root}))
```

Ignatius:

1. resolves and validates the exact template root;
2. executes `init(parameters)` as a pure computation;
3. derives a deterministic contract address;
4. creates a keyless instance account controlled by the creator;
5. records a canonical `:contract/open` event and genesis commit; and
6. returns the contract address.

The instance internally binds:

```text
ignatius.contract/template → template root
ignatius.contract/state    → current state root
ignatius.contract/head     → current commit root
ignatius.contract/history  → ordered commit roots
ignatius.contract/creator  → creator account
```

These are implementation bindings. Contract source sees an explicit `state`
argument, not actor-local global state.

## Submitting events

Parties interact by submitting data:

```clojure
(contract/submit work-order
  {:action :accept})
```

The signed operation includes the expected current head:

```clojure
(contract/apply
  work-order
  expected-head-root
  event-payload)
```

Ignatius never trusts identity fields supplied by the payload. It overwrites the
reserved fields with verified ledger facts:

```clojure
{:contract contract-address
 :template template-root
 :signer verified-transaction-origin
 :transaction transaction-root
 :timestamp ledger-timestamp
 :previous-head current-head-root}
```

The reducer receives:

```clojure
(apply-event current-state verified-event)
```

A result of `{:ok next-state}` creates a new immutable commit, advances the
instance head, appends history, and returns a committed result. A result of
`{:error value}` returns the domain rejection without advancing contract state.

The expected-head check prevents a client from unknowingly applying an event to
stale state.

## State, history, views, and simulation

```clojure
(contract/state work-order)
(contract/history work-order)
(contract/view work-order 'summary)

(contract/simulate work-order
  {:action :milestone/approve
   :id :design})
```

A view executes a pinned pure function against the current state.

Simulation runs the real transition with a verified event but does not advance
the contract head. Its result commits `:contract/committed false` and reports the
hypothetical state root.

## Commit evidence

Each accepted event creates a canonical commit:

```clojure
{:record/type :contract/commit
 :contract/address contract-address
 :contract/template template-root
 :contract/parent previous-head-root
 :contract/event verified-event-root
 :contract/signer signer
 :contract/previous-state previous-state-root
 :contract/state next-state-root
 :contract/transaction transaction-root
 :contract/timestamp ledger-timestamp}
```

The surrounding Ignatius transaction receipt additionally proves execution
against the chain's previous and resulting global state roots.

## Work-order example

[`examples/work_order_contract.hal`](../examples/work_order_contract.hal)
publishes a work-order reducer with:

- exact terms-root pinning;
- independent buyer and supplier acceptance;
- supplier-only milestone submission;
- buyer-only approval; and
- a pure `summary` view.

Typical interaction:

```clojure
(def work-order
  (contract/open
    'contracts/work-order@1
    {:buyer alice
     :supplier bob
     :terms terms-root}))

(contract/submit work-order {:action :accept}) ; Alice signs
(contract/submit work-order {:action :accept}) ; Bob signs

(contract/submit work-order
  {:action :milestone/submit
   :id :design
   :evidence evidence-root})

(contract/submit work-order
  {:action :milestone/approve
   :id :design})

(contract/view work-order 'summary)
```

The publisher supplies reusable rules. The creator opens one agreement. The
parties govern its lifecycle through independently signed events. Ignatius
verifies identity, executes the reducer, and commits the resulting roots.
