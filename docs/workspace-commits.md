# Workspace commit DAGs

`ignatius.workspace` defines the portable collaboration graph that sits between
immutable Hara values and mutable scoped refs.

```text
verified HCV0 workspace values
        ↓
immutable workspace commit candidates
        ↓
user / proposal / release refs
        ↓
accepted main or release ref
        ↓
linear Ignatius admission and receipt evidence
```

Tracking issue: [#13](https://github.com/greenways-ai/ignatius/issues/13).

## Immutable candidates and accepted heads

A workspace commit is represented by the canonical
`:workspace/commit-candidate` value introduced in the build-record vocabulary:

```clojure
{:record/type :workspace/commit-candidate
 :record/version 1
 :record/extensions {}

 :workspace/id "world/orbital-station"
 :workspace/root nil

 :commit/parent-roots [alice-commit-root bob-commit-root]
 :commit/state-root merged-world-root
 :commit/operation-root merge-operation-root
 :commit/merge-base-root base-commit-root
 :commit/merge-policy-root scene-merge-policy-root
 :commit/author-evidence verified-ledger-evidence
 :commit/execution-provenance execution-provenance
 :commit/metadata {}}
```

The word “candidate” is intentional. The value may exist before any branch,
proposal or release ref selects it. Selection does not rewrite the record or
produce a second commit identity:

```text
candidate root CM
  ├── proposal/merge-51 -> CM
  ├── user/alice       -> CM
  └── main             -> CM
```

The root remains `CM` in every context. A signed ref-advance admission and its
receipt prove which selection became authoritative and when.

## Three commit shapes

The portable validator distinguishes three shapes.

### Genesis

```clojure
{:commit/parent-roots []
 :commit/state-root initial-workspace-root
 :commit/merge-base-root nil
 :commit/merge-policy-root nil}
```

A workspace may have multiple unaccepted genesis candidates, for example during
independent offline creation. Acceptance policy decides which root becomes the
initial `main` head.

### Edit

```clojure
{:commit/parent-roots [previous-commit-root]
 :commit/state-root edited-workspace-root
 :commit/operation-root edit-operation-root
 :commit/merge-base-root nil
 :commit/merge-policy-root nil}
```

An ordinary edit has exactly one parent. Merge-only fields on a one-parent
commit are rejected rather than ignored.

### Merge

```clojure
{:commit/parent-roots [left-commit-root right-commit-root]
 :commit/state-root merged-workspace-root
 :commit/operation-root merge-operation-root
 :commit/merge-base-root base-commit-root
 :commit/merge-policy-root merge-policy-root}
```

A merge has two or more ordered parents and requires both an explicit merge base
and merge-policy root. The validator proves that the base is an ancestor of
every parent before admitting the decoded commit to the verified graph.

## Verified decoded commit store

The block store remains responsible for immutable bytes and content roots.
`ignatius.workspace/commit-store` is a decoded index used after block
verification:

```clojure
{:workspace/commit-store-version 1
 :workspace/commits
 {commit-root decoded-canonical-commit}}
```

Insertion requires an explicit verifier:

```clojure
(workspace/register-commit
  verify-root
  commit-store
  candidate-root
  decoded-commit)
```

`verify-root` must recompute or otherwise prove the canonical HCV0 root. A
portable VM might load and verify the block through `ignatius.storage`, decode it,
and then pass a verifier tied to the verified bytes.

The store enforces:

- canonical record type, version and required fields;
- verified author evidence;
- no nil parent roots;
- no duplicate parent roots;
- no direct self-parent;
- parent-before-child admission;
- same workspace ID across parent edges;
- merge-only fields only on multi-parent commits;
- explicit merge base and policy for merges; and
- merge-base ancestry across every parent.

Exact reinsertion is idempotent. A different decoded value under an existing
root is a hard conflict.

## Why parent-before-child admission matters

The decoded store admits a child only after every parent is present. Therefore a
new edge always points to an already verified root:

```text
C10 admitted
  ↓
CA and CB admitted
  ↓
CM admitted with parents [CA CB]
```

This gives the in-memory graph a simple acyclicity guarantee. A child cannot
create an indirect cycle through a parent that has not yet been admitted, and a
direct self-parent is explicitly rejected.

The underlying block store may receive blocks in any order. Parent-before-child
is a rule for the verified decoded graph used by ancestry and merge validation,
not an object-store upload restriction.

## Ancestry

```clojure
(workspace/ancestor? store ancestor-root descendant-root)
(workspace/ancestry-roots store descendant-root)
```

A root is considered its own ancestor. Shared ancestors are returned once:

```text
        CA
       ╱  ╲
C10 ──     CM
       ╲  ╱
        CB
```

The ancestry of `CM` contains four roots:

```clojure
[CM CA CB C10] ; indexed vector-queue traversal order
```

Callers should rely on membership and parent order, not treat ancestry traversal
order as global commit ordering. Authoritative ordering comes from accepted ref
advancements on the linear Ignatius ledger.

The VM does not execute this history graph. It loads one selected code root, one
selected state root and explicit input roots. Ancestry exists for collaboration,
review, merge-base selection, provenance and retention.

## Scoped branch refs

The storage contract separates scope and name:

```text
scope: workspace/world/orbital-station

name:  main
       user/alice
       user/bob
       proposal/merge-51
       release/1.0.0
```

Portable helpers construct the stable names:

```clojure
(workspace/workspace-scope "world/orbital-station")
(workspace/user-ref-name "alice")
(workspace/proposal-ref-name "merge-51")
(workspace/release-ref-name "1.0.0")
```

A mutable ref may select only a commit root present in the verified decoded
store:

```clojure
(workspace/select-memory-ref
  store
  backend
  "world/orbital-station"
  "proposal/merge-51"
  nil
  merge-commit-root
  authorization-root)
```

A non-nil expected root must also be present. This prevents the portable
collaboration layer from advancing refs to opaque or unverified commit values.

## Fast-forward policy

The storage layer provides mechanism: exact-root compare-and-set. The workspace
layer can add policy:

```clojure
(workspace/fast-forward-memory-ref
  store backend workspace-id "main"
  expected-root desired-root authorization-root)
```

Before CAS, the helper verifies that the expected root is an ancestor of the
desired root. It therefore rejects a rewind such as:

```text
main: CM -> CA
```

A stale but otherwise valid request still reaches storage CAS and reports the
actual accepted head:

```clojure
{:error :storage/ref-conflict
 :ref/expected-root C10
 :ref/actual-root CM
 :ref/desired-root CA}
```

Fast-forward is a policy helper, not an intrinsic property of every ref. A
proposal or recovery workflow may deliberately use the generic `select` helper
under its own explicit rules.

## Alice, Bob and a merge

Starting from:

```text
main -> C10
state   W47
```

Alice creates:

```clojure
CA
  parents [C10]
  state   WA

user/alice -> CA
```

Bob creates:

```clojure
CB
  parents [C10]
  state   WB

user/bob -> CB
```

An explicit merge program produces:

```clojure
CM
  parents      [CA CB]
  merge-base   C10
  merge-policy scene-merge-policy-root
  state        WM

proposal/merge-51 -> CM
```

After review, `main` advances through exact CAS:

```text
main: C10 -> CM
```

A delayed request still expecting `C10` receives a conflict with actual root
`CM`. The rejected `CA`, `CB` and any other candidate roots remain in the commit
and block stores.

A release may then pin the exact accepted commit:

```text
release/1.0.0 -> CM
```

## Review records

Reviews use the canonical `:review/decision` record and pin the candidate root as
the exact subject:

```clojure
{:review/id "review/CM/alice"
 :review/subject-id "proposal/merge-51"
 :review/subject-root CM
 :review/decision :approve
 :review/evidence-roots [notes-root]
 :review/recorded-evidence verified-evidence}
```

Moving a proposal ref later does not change the subject of an existing review.

## PostgreSQL and the global ledger

The portable slice uses the pure memory ref adapter for executable conformance.
The PostgreSQL `gwdb.ledger.scoped-ref` adapter supplies the same exact-root CAS
semantics with transaction-scoped advisory locks.

The next #13 slice adds signed ref-advance admission:

```text
signed transaction
  -> exact candidate root and expected ref root
  -> verified workspace/authority policy
  -> commit graph validation
  -> PostgreSQL scoped-ref CAS
  -> canonical acceptance result root
  -> transaction receipt and global chain ordering
```

The global chain remains linear. Only workspace collaboration history is a DAG.
Existing reducer-contract histories remain the simpler linear model for
agreements, approvals and workflows that do not need branches.

## Deliberate limits of the portable slice

- Commit values are decoded only after an injected root verifier succeeds.
- The module does not encode arbitrary Hara maps into HCV0 bytes.
- The memory backend declares single-writer consistency.
- Merge policies are pinned roots but are not executed by this module.
- There is no automatic merge-base discovery; the supplied base is validated.
- There is no ref deletion API.
- Acceptance evidence and workspace authority policy are added at signed ledger
  admission, not hidden inside the block or ref store.
