# Signed workspace main policy publication

The portable acceptance law defines what a workspace `main` policy means. This
slice binds publication of that immutable policy to ordinary Ignatius account
admission without yet granting permission to advance `main`.

## Canonical policy

The published value is the same `:attestation/claim` produced by
`ignatius.workspace-acceptance/main-policy-value`:

```clojure
{:attestation/claim :workspace/main-policy-v1
 :attestation/subject-id workspace-id
 :attestation/subject-root workspace-id
 :attestation/issuer-evidence
 {:ledger/signer authority-root
  :ledger/timestamp recorded-at
  ...}
 :attestation/scope :workspace/main
 :attestation/audience :workspace/reviewers
 :record/extensions
 {:workspace/policy-kind :unanimous-reviewers-v1
  :workspace/reviewer-roots reviewer-roots}}
```

The reviewer vector is ordered, non-empty and duplicate-free. Every reviewer
must already be represented by an immutable Ignatius root. Order is part of the
policy root, so `[alice bob]` and `[bob alice]` are different policies even though
they contain the same accounts.

## Signed publication

The signing request derives the transaction origin from the supplied Ed25519
public key and constructs the exact policy root server-side. The client signs the
standard Ignatius transaction payload for a constant operation returning that
policy root.

```text
verify network and cost limit
  -> derive account origin and controller
  -> read exact account sequence
  -> validate workspace and reviewer vector
  -> reconstruct and project canonical policy
  -> build standard transaction signing payload
```

Submission repeats the reconstruction under the locked linear network head,
verifies the signature, and performs a create-only ref update:

```text
scope    = workspace/<workspace-id>
name     = policy/main
expected = nil
wanted   = canonical policy root
authority = verified transaction origin
```

On success, the same database transaction inserts and executes the signed
transaction, verifies that the receipt result root is the policy root, commits
one linear block, and binds the receipt to that block.

## Conflict semantics

`policy/main` is immutable in v1. Once selected, attempts to publish the same or
a different policy return `storage/ref-conflict` before transaction insertion.
They do not consume account sequence or advance block height. Alternative policy
values remain immutable and may be inspected, but they have no authority unless
a future explicit policy-rotation protocol selects them.

## Projection

`WorkspaceMainPolicy` is a rebuildable PostgreSQL projection containing:

- exact policy root;
- workspace identity root;
- authority root;
- reviewer-vector root; and
- recorded-at value.

Every projected row is verified by reconstructing the complete canonical
attestation. The projection is an index, not policy identity.

## Generated client contract

The generated TypeScript surface exposes two operations:

```ts
workspaceMainPolicySigningRequest(
  network,
  publicKey,
  workspaceIdRoot,
  reviewerRootsRoot,
  recordedAt,
  costLimit
)

submitWorkspaceMainPolicy(
  network,
  publicKey,
  sequence,
  workspaceIdRoot,
  reviewerRootsRoot,
  recordedAt,
  signature,
  costLimit
)
```

The signing response includes the exact `policy_root`, `operation_root` and
`signing_payload`. The submission result is a discriminated success-or-conflict
value, allowing clients to retain an unselected policy root without mistaking it
for the active workspace policy.

## Deliberate boundary

Publishing a policy does not advance `main`. The next slice will consume the
selected policy root, exact current approval roots, a proposed candidate and an
exact expected `main` root to construct and sign a canonical
`:workspace/main-accepted-v1` attestation.
