# Signed workspace proposal publication

A proposal is an immutable workspace commit selected for review. Publishing a
proposal does not advance `main`, rewrite the commit or grant release authority.

## Deterministic identity

```text
scope  workspace/<workspace-id>
name   proposal/<candidate-commit-root-hex>
root   candidate-commit-root
```

The exact candidate root is both the review subject and the proposal identity.
There is no mutable, client-selected proposal ID that can later be redirected to
a different commit.

## Canonical intent

Proposal publication reuses the canonical `:workspace/ref-update-intent` record
family with a distinct constrained policy:

```clojure
{:record/type :workspace/ref-update-intent
 :record/version 1
 :record/extensions {}
 :workspace/id "world/orbital-station"
 :ref/scope "workspace/world/orbital-station"
 :ref/name "proposal/<candidate-root>"
 :ref/expected-root nil
 :ref/desired-root candidate-root
 :ref/authorization-root verified-origin-root
 :ref/policy :proposal-publication-v1
 :ref/metadata {}}
```

Expected root is always `nil`. The operation can create a proposal ref but cannot
replace one. Duplicate publication reaches exact compare-and-set and returns a
conflict with the already published root.

## Admission order

```text
lock linear network head
  -> verify account, controller and sequence
  -> verify candidate commit and workspace
  -> derive proposal scope, name, authority and policy
  -> reconstruct exact intent and operation roots
  -> verify Ed25519 transaction signature
  -> exact scoped-ref CAS: nil -> candidate root
  -> insert and execute the signed transaction
  -> receipt result root = proposal intent root
  -> commit one linear block and bind the receipt
```

A duplicate or concurrent collision returns before transaction insertion. It
does not consume the account sequence or advance the global block head. If a
later assertion fails, PostgreSQL transaction rollback also rolls back the ref
creation.

## Branch relationship

Proposal publication does not require fast-forward ancestry. Two sibling
commits may both be valid proposals:

```text
        CA -> proposal/<CA>
       /
C0 ---
       \
        CB -> proposal/<CB>
```

Ancestry becomes relevant when a later policy decides whether a proposal may
advance `main`. Publication only proves that the candidate is a verified commit
from the named workspace and that a verified origin signed its review intent.

## Authority boundary

The proposal API cannot target:

```text
main
user/*
release/*
proposal/<another-root>
```

The proposal name is derived from the desired root. Personal branches remain
covered by `personal-fast-forward-v1`. Shared acceptance and releases require
separate policy and review evidence.
