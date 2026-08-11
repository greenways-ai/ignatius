# Convex-style accounts and actors

Ignatius implements Convex-shaped account execution directly over HCV0 state.
It does not embed the Java CVM or introduce a second value codec.

## Account v2

Historical account roots remain valid. New accounts use the version-2 canonical
record:

```clojure
{:sequence    0
 :environment {}
 :metadata    {}
 :key         <external-ed25519-key-or-nil>
 :controller  <internal-account-or-authority-or-nil>
 :parent      <creating-account-or-nil>}
```

`key` verifies externally submitted transactions. `controller` is an internal
authority value. Actors are keyless: their key is Hara `nil`, while their
controller and parent are the account that deployed them.

The historical `account-value-controller-root` function remains as a signing-key
compatibility alias. New runtime code uses:

- `account-value-key-root`
- `account-value-authority-root`
- `account-value-parent-root`

Account updates preserve whether an imported root is v1 or v2. Setting a key or
controller upgrades a v1 account into a v2 successor without rewriting history.

## Runtime profile

`runtime-profile/convex-profile-put` commits a canonical source profile. The
profile maps Convex-shaped symbols such as `+`, `assoc`, `account`, `deploy`,
`call`, and `query` to native Ignatius primitive or operation identities.

A compiler places this profile root in the transaction `runtime-root`. Source
symbols are resolved before signing, so the ledger executes the canonical
operation graph rather than ambient compiler state.

## Actor operations

Three actor forms are represented as special operations:

```text
actor/deploy
actor/call
actor/query
```

`deploy` derives a deterministic address, creates a keyless account, switches
the execution context to that account, and executes the initializer.

`call`:

1. evaluates the target and arguments in the caller;
2. resolves the method in the target account;
3. requires `{:callable true}` metadata on the definition;
4. switches `address` to the target while preserving `origin`;
5. sets `caller` to the immediate calling account;
6. executes the persistent function;
7. retains the callee state and restores the caller context.

`query` follows the same path but discards all callee state on successful return.
Costs remain charged.

Expected runtime errors still abort the enclosing transaction. The transaction
layer retains the predecessor state on failure.

## Definition metadata

Callable status belongs to the account definition rather than to an arbitrary
function value. The compiler lowers:

```clojure
(defn ^:callable increment! [] ...)
```

to a normal function definition and includes `increment!` in the deployment
operation's canonical callable-symbol vector. After the initializer succeeds,
Ignatius verifies every declared symbol resolves to a persistent function and
attaches:

```clojure
{:callable true}
```

to the actor account's definition metadata. The closed
`account/set-definition-metadata` primitive is also available for a separately
authorized top-level metadata transition.

## Counter demo

[`examples/counter_actor.hal`](../examples/counter_actor.hal) describes the
source program. The PostgreSQL round-trip test constructs its canonical
operation graph and proves:

```clojure
[(call counter increment!)
 (call counter increment!)
 (query counter current)]
;; => [1 2 2]
```

It also verifies that the deployed account is version 2, keyless, controlled by
its creator, and stores `n = 2` after the read-only query.

## Initial compatibility boundary

This slice establishes accounts, actors, callable methods, context switching,
state rollback for queries, and a canonical Convex-shaped core profile. Actor
operations and account mutation primitives are initially admitted as signed
top-level operations; actor initializers and method bodies use the recursive v1
operation evaluator.

It does not yet implement native balances, offers, transfer, memory allowance,
trust monitors, `eval-as`, or Convex binary encoding. Those can be added as
native Ignatius state transitions without changing the actor execution model.