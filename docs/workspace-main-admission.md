# Signed workspace main admission

This slice exercises the immutable `policy/main` authority published by the
previous release. A shared `main` transition is accepted only when one canonical
attestation pins the complete policy, proposal, review and compare-and-set edge.

## Canonical acceptance

The signed value is the PostgreSQL equivalent of
`ignatius.workspace-acceptance/main-acceptance-value`:

```clojure
{:record/type :attestation/claim
 :attestation/id "main-acceptance/<workspace>/<candidate-root>"
 :attestation/claim :workspace/main-accepted-v1
 :attestation/subject-id "proposal/<candidate-root>"
 :attestation/subject-root candidate-root
 :attestation/context-root policy-root
 :attestation/evidence-roots [review-root-a review-root-b]
 :attestation/issuer-evidence
 {:ledger/signer authority-root
  :ledger/timestamp recorded-at
  ...}
 :attestation/scope :workspace/main
 :attestation/audience :workspace/members
 :record/extensions
 {:workspace/id workspace-id
  :ref/expected-root expected-main-root
  :ref/desired-root candidate-root
  :ref/policy :main-acceptance-v1}}
```

The authority signs the exact candidate, policy, ordered review vector and
expected `main` root. None of those values can be substituted by the admission
server after signing.

## Evidence validation

The selected `policy/main` row supplies an ordered reviewer vector. The
acceptance review vector must have exactly the same length. At every position,
Ignatius verifies that the supplied review root:

1. is a valid canonical `WorkspaceReview` projection;
2. belongs to the same workspace and exact candidate;
3. was issued by the reviewer at the corresponding policy position;
4. contains the decision `approve`;
5. is still selected by `review/<candidate>/<reviewer>`; and
6. is selected under that reviewer’s own authorization root.

This makes historical but superseded approvals insufficient. A later rejection,
withdrawal or replacement approval changes the reviewer ref and invalidates the
old evidence root for future acceptance.

## Candidate and ancestry validation

The candidate must already be selected by its deterministic proposal ref.

```text
proposal/<candidate-root> -> candidate-root
```

The first transition may use `expected = nil` only for a verified zero-parent
genesis commit. Every later transition requires the expected commit to exist in
the same workspace and be an ancestor of the proposed candidate.

## Atomic admission order

```text
lock linear network head
  -> verify account, controller and sequence
  -> verify selected policy and authority
  -> verify proposed candidate and ancestry
  -> verify every exact current approval root
  -> reconstruct canonical acceptance root
  -> verify Ed25519 transaction signature
  -> exact main compare-and-set
  -> execute transaction returning acceptance root
  -> verify receipt result root
  -> commit one linear block and bind receipt
```

The mutable selection remains simple:

```text
scope         workspace/<workspace-id>
name          main
expected      exact previous main root
wanted        exact candidate root
authorization exact selected policy root
```

The transaction result is the immutable acceptance attestation, while the ref
result is the candidate commit. This keeps evidence and selection distinct.

## Conflicts

A stale `main` compare-and-set returns `storage/ref-conflict` with the accepted
candidate root. The conflicting acceptance attestation and all reviews remain
immutable, but no transaction is inserted, no account sequence is consumed and
no global block is committed.

## Projection and client surface

`WorkspaceMainAcceptance` is a rebuildable index over canonical acceptance
attestations. It stores workspace, authority, expected root, candidate, policy,
review-vector root and recorded-at value, and verifies every row by complete
canonical reconstruction.

The generated client contract exposes a signing-request operation and a signed
submission operation. Both carry the exact policy, review-vector and expected
root rather than a server-computed approval tally.

## Executable conformance lifecycle

The PostgreSQL suite uses two independent RFC 8032 Ed25519 accounts. It publishes
one unanimous policy, two proposal candidates and four reviewer decisions, then
proves:

```text
nil -> C0   accepted genesis bootstrap
C0  -> C1   accepted fast-forward
C0  -> C1   stale retry conflicts after C1 is current
```

Both successful acceptance receipts return their immutable acceptance roots,
while `main` advances to the candidate roots. The stale retry leaves the signing
account sequence and the eleven-block network height unchanged. A reversed
review-evidence vector is rejected before signing because reviewer position is
part of the selected policy.

## Boundary

This completes policy-gated shared `main`. It does not publish releases. The
next slice will create immutable `release/<version>` selections that pin an
already accepted main root, its acceptance evidence and the governing policy.
