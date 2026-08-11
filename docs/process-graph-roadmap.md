# Process graph and collaborative timeline roadmap

Ignatius already has the hard part that a graph-oriented build ledger needs:
immutable HCV0 values, labelled `CellRef` edges, HCP0 graph packs, signed
transactions, deterministic execution, account sequencing, receipts, snapshots,
and reducer contracts with optimistic expected-head checks.

The next direction is therefore additive. Ignatius should specialise in
canonical process, artifact, timeline, commit and attestation semantics without
rewriting the existing PostgreSQL ledger or changing historical roots.

Tracking epic: [#9](https://github.com/greenways-ai/ignatius/issues/9).

## Architectural layers

```text
Value DAG
  canonical Hara values, programs, process runs, artifacts and graph nodes

Index/ref layer
  stable IDs and names resolved to exact immutable value or commit roots

Workspace commit DAG
  branches, proposals, reviews and multi-parent merges

Global Ignatius ledger
  signed admission, account ordering, accepted heads and execution receipts
```

These layers solve different problems and should not be collapsed into one
database representation.

## What fits

| Proposal | Decision | Reason |
| --- | --- | --- |
| Immutable block store plus conditional refs | Adopt as an interface boundary | `Cell`, `CellRef` and HCP0 already provide the immutable verified-block semantics. Extract adapters rather than create a second SQL model. |
| Stable IDs alongside content roots | Adopt | A stable scene node, document, artifact or process identity must survive while its exact immutable root changes. |
| Multi-parent commit DAG | Adopt for workspaces | Branches and merges belong above the global ledger. The global chain remains linear and records accepted head advancement. |
| Content-addressed definitions and namespace commits | Adopt incrementally | Definition-level identity and binding-level merges suit collaborative Hara programs. Existing module/account bindings remain compatible during migration. |
| Compiler artifact provenance | Adopt | Semantic AST/operation roots remain identity; bytecode, Wasm and native artifacts are rebuildable caches keyed by exact provenance. |
| Required versus granted effects | Adopt | Pure execution should emit an effect plan. File, network, secret, clock, randomness and GPU authority must never be ambient. |
| Prolly-tree-style indexes | Prototype later | A new canonical format requires fixed chunking, cross-runtime test vectors, structural diff and merge, plus measured workloads that justify it. |
| Datoms as the canonical world model | Reject | Datoms may be useful as rebuildable query projections, but would flatten ordered syntax, typed records, component locality and executable Hara values. |
| Replace HCV0 with DAG-CBOR | Reject for existing values | Re-encoding would change every historical root. New collection codecs may be versioned without invalidating HCV0. |
| Replace PostgreSQL execution immediately | Reject | The existing runtime remains the authoritative implementation and conformance oracle until a portable VM dual-runs the same roots. |

## Ownership boundary

Ignatius owns generic, application-neutral protocol records:

- process definitions, runs, checkpoints, inputs and outputs;
- stable artifact identities and exact immutable artifact versions;
- signed timeline events, reviews, approvals and attestations;
- workspace commits, branches and merge evidence;
- execution provenance, receipts, capabilities and effect plans; and
- rebuildable query projections that retain canonical roots.

Applications such as Hestia own product policy and experience:

- agent profiles and mandates;
- private rooms, invitations and membership;
- document OT/CRDT policy and editing UX;
- negotiation, continuity and recovery ceremonies; and
- application-specific access rules and projections.

A document can therefore be an Ignatius artifact governed by a generic signed
workflow without moving document editing semantics into this repository. The
same distinction applies to scene graphs, DOM trees and AI orchestration.

## Delivery plan

### 1. Signed linear build timeline

Issue [#10](https://github.com/greenways-ai/ignatius/issues/10) adds a portable
reducer contract over the existing signed contract runtime. It records process
runs, artifact head changes and reviews while preserving all database-ledger
code.

This is intentionally a linear authoritative timeline. It proves the shared
record vocabulary and user value before branch storage is introduced.

### 2. Canonical record vocabulary

Issue [#11](https://github.com/greenways-ai/ignatius/issues/11) specifies
versioned process, artifact, timeline and attestation records, including the
stable-ID/content-root distinction and rules for logical cycles.

### 3. Storage seam

Issue [#12](https://github.com/greenways-ai/ignatius/issues/12) extracts
provider-neutral immutable block and scoped compare-and-set ref interfaces from
the semantics already implemented by `Cell`, `CellRef` and snapshots.

### 4. Workspace commit DAG

Issue [#13](https://github.com/greenways-ai/ignatius/issues/13) introduces
one-or-more-parent workspace commits and scoped branch refs. Candidate branches
remain immutable even when a stale ref update is rejected; the global ledger
records which head became accepted.

### 5. Large persistent indexes

Issue [#14](https://github.com/greenways-ai/ignatius/issues/14) benchmarks and
specifies HPT0 only after real entity, DOM and namespace workloads demonstrate
the need. Structural diff and three-way merge are requirements, not assumptions.

### 6. Collaborative Hara code graph

Issue [#15](https://github.com/greenways-ai/ignatius/issues/15) adds
content-addressed definitions, namespace commits, dependency closure validation,
binding-level merge, and compiled-artifact provenance.

### 7. Portable execution

Issue [#16](https://github.com/greenways-ai/ignatius/issues/16) builds a
verified block loader, execution overlay and portable VM. It dual-runs against
the PostgreSQL runtime and compares status, result root, state root, cost and
effects.

### 8. Structural merge programs

Issue [#17](https://github.com/greenways-ai/ignatius/issues/17) publishes
content-addressed Hara merge policies for scene, DOM, document, code and process
graphs. Conflicts remain canonical values that people or agents can inspect and
resolve.

### 9. Projections and retention

Issue [#18](https://github.com/greenways-ai/ignatius/issues/18) adds rebuildable
process, artifact, review and ancestry projections plus explicit reachability
and garbage-collection roots.

### 10. Attestations and capabilities

Issue [#19](https://github.com/greenways-ai/ignatius/issues/19) defines signed
claims, required/granted capability sets, effect plans and effect receipts for
AI and build execution.

## Compatibility invariants

Every phase must preserve these properties:

1. Existing HCV0 and HCP0 roots remain valid and unchanged.
2. Existing account, transaction, admission, receipt, block and snapshot
   semantics remain supported.
3. PostgreSQL remains an authoritative backend, not an implementation detail to
   delete.
4. New mutable names are scoped refs with explicit compare-and-set semantics.
5. Canonical state stays in Hara values; SQL indexes and datom-like views remain
   rebuildable projections.
6. The global Ignatius ledger remains linear even when workspace collaboration
   becomes branchable.
