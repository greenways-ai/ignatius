# Signed personal workspace refs

The first signed workspace-ref admission policy deliberately covers only a
verified account's personal branch.

```text
workspace scope  workspace/<workspace-id>
ref name         user/<verified-origin-address-root>
policy           personal-fast-forward-v1
```

Clients submit a workspace ID, an exact expected commit root and an exact desired
commit root. They do not choose the scope, name, authorization root or policy.
Those fields are derived by Ignatius and committed into the signed intent.

## Canonical intent

```clojure
{:record/type :workspace/ref-update-intent
 :record/version 1
 :record/extensions {}
 :workspace/id "world/orbital-station"
 :ref/scope "workspace/world/orbital-station"
 :ref/name "user/<address-root>"
 :ref/expected-root previous-commit-root
 :ref/desired-root desired-commit-root
 :ref/authorization-root address-root
 :ref/policy :personal-fast-forward-v1
 :ref/metadata {}}
```

The portable module derives and validates the same value before a client asks a
wallet to sign. PostgreSQL reconstructs the complete constrained value and signs
the ordinary Ignatius transaction payload whose operation is a constant that
returns the intent root.

## Admission order

```text
lock linear network head
  -> verify account, controller and sequence
  -> verify desired and expected commit projections
  -> require one workspace and fast-forward ancestry
  -> reconstruct the exact intent and operation roots
  -> verify the Ed25519 transaction signature
  -> exact scoped-ref compare-and-set
  -> insert and execute the signed transaction
  -> receipt result root = intent root
  -> commit one linear block and bind the receipt
```

A stale compare-and-set returns before transaction insertion and account-sequence
advancement. The global block head is unchanged. Immutable candidate commits,
the intent value and its operation may remain available for inspection or a new
signed attempt.

If a later assertion fails after compare-and-set, PostgreSQL transaction rollback
also rolls back the ref update. Ref selection and linear ledger admission are
therefore one atomic database boundary.

## Authority boundary

This policy cannot write:

```text
main
proposal/*
release/*
user/<another-origin>
```

Those names need explicit shared workspace policy, review evidence or release
authority. They are not implied by possession of an account key and are not
hidden inside the generic scoped-ref store.
