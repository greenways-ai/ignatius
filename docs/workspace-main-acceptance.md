# Workspace main acceptance

Ignatius keeps the global ledger linear while workspace candidates remain a
separate immutable commit DAG. Selecting a shared `main` head therefore needs a
policy boundary above generic ref storage.

This document specifies the first portable boundary. It does not implement a
general governance language. It defines one deliberately narrow law that can be
implemented identically by memory, PostgreSQL and remote adapters.

## Immutable policy

A workspace publishes exactly one v1 policy at:

```text
scope = workspace/<workspace-id>
name  = policy/main
root  = canonical :attestation/claim
```

The policy claim is `:workspace/main-policy-v1`. It pins:

- the workspace identity;
- the authority account permitted to submit accepted-main transitions;
- an exact ordered vector of reviewer roots; and
- `:unanimous-reviewers-v1` as the policy kind.

The vector must be non-empty and contain no nil or duplicate reviewer roots. Its
order is part of policy identity. V1 is create-only: changing the reviewer set or
authority requires a future explicit policy-rotation protocol rather than an
ordinary storage overwrite.

## Immutable acceptance evidence

An accepted-main transition is another canonical `:attestation/claim`:

```clojure
{:attestation/claim :workspace/main-accepted-v1
 :attestation/subject-root candidate-root
 :attestation/context-root policy-root
 :attestation/evidence-roots [review-root-a review-root-b]
 :record/extensions
 {:workspace/id workspace-id
  :ref/expected-root expected-main-root
  :ref/desired-root candidate-root
  :ref/policy :main-acceptance-v1}}
```

The claim pins the complete decision. A server cannot substitute another
candidate, policy, review, or expected main root after the authority signs the
value.

## Review rule

For every reviewer root in the policy, the corresponding evidence root must:

1. decode as a canonical `:review/decision`;
2. name the exact proposed candidate;
3. be issued by the reviewer at the same vector position;
4. contain the canonical decision `:approve`; and
5. still be selected by `review/<candidate>/<reviewer>`.

The final requirement rejects superseded approvals. An old approval remains an
immutable and inspectable statement, but it cannot authorize acceptance after
the reviewer has selected a rejection, withdrawal, or newer approval.

## Candidate rule

The candidate must be a verified workspace commit and must already be visible at
`proposal/<candidate-root>`.

- `nil -> candidate` may bootstrap `main` only when the candidate is a genesis
  commit.
- Every later transition must be a fast-forward from the exact expected main
  root.
- Exact compare-and-set remains the final concurrency boundary. A stale expected
  root reports the accepted root and preserves all candidate and evidence
  values.

## Authority versus storage

The generic ref store does not decide whether reviews are sufficient. The
acceptance module validates policy, proposal, review and ancestry evidence first,
then issues one ordinary CAS request:

```text
scope         workspace/<workspace-id>
name          main
expected      exact previous main root
wanted        exact candidate root
authorization exact policy root
```

The portable memory adapter proves the policy algebra. The next delivery slice
will bind the same value to account sequencing, Ed25519 signatures, PostgreSQL
CAS, a transaction receipt and one linear Ignatius block.

## Non-goals of v1

- weighted votes or thresholds;
- mutable reviewer membership;
- policy rotation;
- implicit organization roles;
- accepting an unpublished candidate;
- counting historical reviews that are no longer current; or
- making the global Ignatius chain branchable.

These can be added as explicit policy versions without changing the commit DAG,
proposal, review, or storage contracts established here.
