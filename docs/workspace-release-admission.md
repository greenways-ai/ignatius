# Signed workspace release admission

A workspace release is an immutable, versioned selection of the candidate that
is currently accepted at `main`. It is not a second branch-moving operation and
it cannot reinterpret historical reviews. The release claim pins the selected
policy and the exact accepted-main evidence that authorized the candidate.

## Canonical release claim

```clojure
{:record/type :attestation/claim
 :attestation/id "release/<workspace-id>/<version>"
 :attestation/claim :workspace/release-published-v1
 :attestation/subject-id "release/<version>"
 :attestation/subject-root candidate-root
 :attestation/context-root policy-root
 :attestation/evidence-roots [acceptance-root]
 :attestation/issuer-evidence
 {:ledger/signer authority-root
  :ledger/timestamp recorded-at
  ...}
 :attestation/scope :workspace/release
 :attestation/audience :workspace/members
 :record/extensions
 {:workspace/id workspace-id
  :release/version version
  :release/acceptance-root acceptance-root
  :ref/expected-root nil
  :ref/desired-root candidate-root
  :ref/policy :release-publication-v1}}
```

The version, candidate, policy, acceptance and recorded-at evidence are all part
of release identity. A server cannot substitute another candidate or acceptance
after the authority signs the transaction payload.

## Authority and current-main checks

Before constructing a signing payload, Ignatius verifies:

1. `policy/main` selects the supplied policy root under the signing origin;
2. `main` currently selects the supplied candidate under that policy root;
3. the candidate is a valid commit in the named workspace;
4. the acceptance projection names the same workspace, authority, candidate and
   policy; and
5. the acceptance was actually admitted to the authoritative linear chain.

The fifth condition is stronger than structural validity. A stale main attempt
may construct a perfectly valid immutable acceptance value before its ref CAS
conflicts. Such a value must not authorize a release.

## Proving the exact accepted transition

`workspace-main-submit` records an append-only `WorkspaceMainSelection`
binding only after the exact main CAS, signed transaction, receipt, block
commit and receipt binding all succeed. The binding pins the workspace,
authority, expected and desired roots, selected policy, ref version, network,
transaction, receipt, block and recorded-at value.

Release admission reconstructs and validates that binding and requires its
block to remain on the current network-head ancestry. A generic transaction
that merely returns an acceptance-shaped root therefore cannot masquerade as
the transition that advanced `main`.

## Create-only release ref

V1 publishes one immutable version through exact CAS:

```text
scope         workspace/<workspace-id>
name          release/<version>
expected      nil
wanted        current main candidate root
authorization selected policy root
```

The transaction result is the immutable release claim root, while the ref selects
the released candidate root. A duplicate version or a competing claim for the
same version returns `storage/ref-conflict` before transaction insertion. It
consumes neither account sequence nor block height.

## Projection and generated client

`WorkspaceRelease` is a rebuildable projection containing:

- release root;
- workspace and authority roots;
- version text;
- candidate, policy and acceptance roots; and
- recorded-at value.

Every row is verified by reconstructing the complete canonical attestation.
Generated TypeScript contracts expose a signing request and a signed submission
result with a discriminated success-or-conflict shape.

## V1 boundaries

- Version names must be non-empty and valid scoped-ref path components.
- Releases are immutable; policy-driven revocation or supersession requires a
  future explicit record family.
- Only the current accepted `main` candidate can be released.
- A release does not move `main` or modify proposal/review state.
- The global Ignatius chain remains linear.
