# Signed workspace review decisions

A review is an immutable decision about one exact published proposal candidate.
The latest decision by a reviewer is selected through a reviewer-specific scoped
ref, while every prior decision remains content-addressed and retrievable.

## Immutable decision

```clojure
{:record/type :review/decision
 :record/version 1
 :record/extensions {}
 :review/id "review/<candidate-root>/<reviewer-root>"
 :review/subject-id "proposal/<candidate-root>"
 :review/subject-root candidate-root
 :review/decision :approve ; :reject or :withdraw
 :review/evidence-roots []
 :review/process-run-id nil
 :review/process-run-root nil
 :review/recorded-evidence
 {:record/type :ledger/evidence
  :record/version 1
  :ledger/signer reviewer-root
  :ledger/timestamp recorded-at
  ...}
 :review/metadata {}}
```

The decision record pins the immutable candidate, reviewer, outcome and signed
recorded-at value. It cannot be reinterpreted if a ref later advances.

## Reviewer-specific ref

```text
scope  workspace/<workspace-id>
name   review/<candidate-root>/<reviewer-root>
root   latest review-decision root
```

One reviewer cannot update another reviewer's ref because the name and
authorization root are derived from the verified transaction origin.

## Exact update intent

The signed transaction returns a canonical `:workspace/ref-update-intent` that
binds both the previous and next immutable review roots:

```clojure
{:ref/expected-root previous-review-root
 :ref/desired-root next-review-root
 :ref/policy :review-decision-v1}
```

An initial decision uses a nil expected root. A later rejection or withdrawal
must name the exact currently accepted review root. A stale writer receives the
actual root and does not consume account sequence or global block height.

## Admission order

```text
lock linear network head
  -> verify account, controller and sequence
  -> verify candidate and deterministic proposal ref
  -> verify expected review belongs to candidate and reviewer
  -> construct canonical decision and exact ref intent
  -> verify Ed25519 transaction signature
  -> exact reviewer-ref compare-and-set
  -> execute the signed transaction
  -> receipt result root = ref-update intent root
  -> commit one linear block and bind the receipt
```

The review record and intent may be constructed before final admission because
they are immutable values. The mutable reviewer ref, account sequence and block
head change only inside the successful PostgreSQL transaction.

## Deliberate boundary

This slice records reviewer statements; it does not decide whether a proposal is
accepted. A later workspace policy can count or qualify exact review roots and
then authorize `main` advancement. Raw storage CAS never invents quorum,
maintainer or release authority.
