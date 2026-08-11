# Signed build timelines

`ignatius.timeline` is a pure reducer contract for recording a signed,
deterministic build history through the existing Ignatius contract, commit and
receipt machinery.

The reducer is application-neutral. It can track AI runs, scene or DOM builds,
document workflows, software releases, or mixed builds that produce several
kinds of immutable artifacts.

The current template emits the canonical v1 records defined by
[`ignatius.record`](../hal/src/ignatius/record.hal). Existing timeline instances
remain pinned to their original immutable template and state shape.

## Execution path

```text
signed transaction
  -> verified signer, transaction, timestamp, contract and previous head
  -> pure timeline/apply-event
  -> canonical workspace, run, artifact, review and timeline records
  -> immutable contract state and commit roots
  -> transaction receipt over previous and resulting global state
```

No new storage codec or database runtime is required for this slice. The records
remain ordinary HCV0 maps and vectors.

## Workspace state

A timeline instance is a canonical `:workspace/build` value:

```clojure
{:record/type :workspace/build
 :record/version 1
 :record/extensions {}

 :workspace/id "world/orbital-station"
 :workspace/kind :scene
 :workspace/name nil
 :workspace/schema-root scene-schema-root
 :workspace/entrypoints {}

 :workspace/participants
 {alice true
  bob true}

 :workspace/status :active

 :workspace/processes {}
 :workspace/artifacts {}
 :workspace/artifact-versions {}
 :workspace/reviews {}
 :workspace/timeline-entries {}
 :workspace/latest-entry-id nil
 :workspace/metadata {}}
```

The indexes are ordinary HCV0 maps. HPT0 remains a later optimisation for
workloads that demonstrate a real flat-map bottleneck.

## Process runs

A process run has a stable run ID and pins the exact process definition root:

```clojure
{:record/type :process/run
 :record/version 1

 :run/id "run/lighting-17"
 :run/workspace-id "world/orbital-station"
 :run/workspace-root nil
 :run/definition-root lighting-agent-definition-root
 :run/status :complete

 :run/input-roots [scene-root-A prompt-root]
 :run/parent-references
 [{:record/type :reference/logical
   :reference/scope-id "world/orbital-station"
   :reference/kind :process/run
   :reference/id "run/layout-9"
   :reference/root nil}]

 :run/output-roots [scene-root-B]
 :run/result-root result-root
 :run/receipt-root model-and-tool-receipt-root
 :run/started-evidence verified-start-evidence
 :run/completed-evidence verified-completion-evidence
 :run/metadata {}
 :record/extensions {}}
```

Starting and completing a run also appends canonical timeline entries. The
current process index is convenient to query without losing transition history.

## Artifact identities and versions

`:workspace/artifacts` maps each stable artifact ID to its current exact version:

```clojure
{:record/type :artifact/version
 :record/version 1

 :artifact/id "scene/main"
 :artifact/kind :scene
 :artifact/content-root scene-root-B
 :artifact/previous-content-root scene-root-A
 :artifact/source-roots [texture-root prompt-root]
 :artifact/producer-run-id "run/lighting-17"
 :artifact/producer-run-root nil
 :artifact/schema-root scene-schema-root
 :artifact/metadata {:label "Lighting pass"}
 :artifact/published-evidence verified-publication-evidence
 :record/extensions {}}
```

`:workspace/artifact-versions` retains every accepted version under its stable ID
and exact content root:

```clojure
{"scene/main"
 {scene-root-A version-A
  scene-root-B version-B}}
```

The caller supplies `:artifact/previous-content-root` as an optimistic
concurrency expectation. The reducer checks it against the accepted current root
and stores ancestry derived from state, not from an untrusted lineage claim.

`:artifact/source-roots` are separate derivation provenance. They identify other
immutable inputs that contributed to the new version. They do not replace the
immediate accepted predecessor.

An exact content root already recorded for a stable artifact cannot be reused to
overwrite the earlier version record.

## Canonical transition entries

Every accepted transition is wrapped in a `:timeline/entry`:

```clojure
{:record/type :timeline/entry
 :record/version 1
 :timeline/id transaction-root
 :timeline/previous-entry-id previous-transaction-root
 :timeline/event artifact-version-value
 :timeline/evidence ledger-evidence-value
 :timeline/subject-reference artifact-logical-reference
 :timeline/sequence nil
 :timeline/metadata {}
 :record/extensions {}}
```

The verified transaction root is the entry ID. An internal context without a
transaction root uses the verified previous contract head as a deterministic
fallback.

The state stores:

```clojure
{:workspace/latest-entry-id tx-complete
 :workspace/timeline-entries
 {tx-start process-start-entry
  tx-publish-A artifact-A-entry
  tx-publish-B artifact-B-entry
  tx-review review-entry
  tx-complete process-complete-entry}}
```

Following `:timeline/previous-entry-id` from the latest entry yields the accepted
build history in reverse order. This avoids adding a vector-append primitive to
the frozen PostgreSQL runtime. The contract history independently pins the state
and commit roots for the same transitions.

## Events

### Initialise a workspace

```clojure
(contract/open
  'timeline/build@2
  {:workspace/id "world/orbital-station"
   :workspace/kind :scene
   :workspace/schema-root scene-schema-root
   :workspace/participants
   {alice true
    bob true}})
```

The compatibility parameter `:participants` remains accepted.

### Start a process

```clojure
(contract/submit timeline
  {:action :process/start
   :process/id "run/lighting-17"
   :process/definition-root lighting-agent-definition-root
   :process/input-roots [scene-root-A prompt-root]
   :process/parent-references
   [{:record/type :reference/logical
     :record/version 1
     :reference/scope-id "world/orbital-station"
     :reference/kind :process/run
     :reference/id "run/layout-9"
     :reference/root nil
     :reference/metadata {}
     :record/extensions {}}]})
```

A run ID cannot be reused. `:process/parent-runs` remains accepted as a
compatibility alias, but new callers should send canonical logical references.

### Publish an artifact version

```clojure
(contract/submit timeline
  {:action :artifact/publish
   :artifact/id "scene/main"
   :artifact/kind :scene
   :artifact/content-root scene-root-B
   :artifact/previous-content-root scene-root-A
   :artifact/source-roots [texture-root prompt-root]
   :artifact/schema-root scene-schema-root
   :artifact/metadata {:label "Lighting pass"}
   :process/id "run/lighting-17"})
```

For an artifact's first version,
`:artifact/previous-content-root` is `nil`. Subsequent updates must name the
exact accepted current root. The producing run must already exist.

The previous event fields `:artifact/root` and `:artifact/previous-root` remain
accepted as compatibility aliases.

### Record a review

```clojure
(contract/submit timeline
  {:action :review/record
   :review/id "review/scene-B/alice"
   :review/decision :approve
   :review/evidence-roots [review-notes-root]
   :review/metadata {:role :art-director}
   :artifact/id "scene/main"
   :artifact/content-root scene-root-B
   :process/id "run/lighting-17"})
```

The resulting `:review/decision` is pinned to one exact subject root. A review of
an obsolete artifact root is rejected rather than silently applying to a later
version. The single `:review/evidence-root` field remains a compatibility alias.

### Complete a process

```clojure
(contract/submit timeline
  {:action :process/complete
   :process/id "run/lighting-17"
   :process/output-roots [scene-root-B]
   :process/result-root result-root
   :process/receipt-root model-and-tool-receipt-root})
```

Only a running process can complete. Completion is immutable.

## Verified evidence

Every accepted run, artifact version, review and timeline entry contains a
canonical `:ledger/evidence` value:

```clojure
{:record/type :ledger/evidence
 :record/version 1
 :ledger/signer verified-account
 :ledger/transaction-root signed-transaction-root
 :ledger/timestamp ledger-timestamp
 :ledger/previous-head-root exact-contract-head
 :ledger/contract-root contract-root
 :ledger/template-root template-root
 :ledger/global-state-root nil
 :record/extensions {}}
```

The contract runtime overwrites `:signer`, `:transaction`, `:timestamp`,
`:previous-head`, `:contract` and `:template` before the reducer runs. Payload
attempts to claim different values therefore do not control the stored evidence.

The containing contract commit additionally pins previous and resulting state
roots. The surrounding transaction receipt proves execution against the global
Ignatius state.

## Domain mappings

### AI processes

- process definition root: exact agent, workflow, model and tool contract;
- process run: immutable inputs, outputs and execution receipt;
- process step: one explicit model or tool boundary;
- checkpoint: durable completed boundary for replay;
- artifact version: generated document, scene, code or evaluation;
- review or attestation: a signed claim against an exact output root.

### Scene graph and DOM builds

- workspace ID: stable world, page or component identity;
- artifact ID: stable scene, DOM, asset or layer name;
- content root: exact immutable graph version;
- process run: import, generation, layout, shader, animation or render pass;
- logical references: node relationships that may form cycles.

### Documents as workflows

- content root: exact canonical document tree or bundle;
- process run: drafting, transformation, analysis, export or signing;
- review: approval, rejection or requested changes against one exact version;
- evidence root: comments, policy output, delivery receipt or external proof.

Document editing algorithms, private-room policy and product UX remain in Hestia
or another application. Ignatius supplies the generic records and signed
lifecycle underneath them.

## Views

Compile and publish `ignatius.timeline` as an ordinary reducer template with:

```text
init              -> ignatius.timeline/init
apply-event       -> ignatius.timeline/apply-event

views:
workspace         -> complete canonical workspace state
summary           -> compact workspace summary
processes         -> current canonical process runs
artifacts         -> current canonical artifact versions
artifact-versions -> complete per-artifact version index
reviews           -> canonical signed review decisions
entries           -> transaction-keyed canonical timeline entries
latest-entry      -> latest canonical timeline entry
```

Every view remains a pure one-argument function over contract state.

## Runtime compatibility

The reducer uses the existing map, vector, equality and conditional operations
supported by the frozen PostgreSQL runtime. The repository validates:

```shell
make hal-check
make hal-test
make db-sql
make db-contracts
```

The full CI suite also executes protocol, recursive runtime, actor and reducer
contract tests against PostgreSQL.

## Template migration

Canonical records change the reducer's immutable template root. Existing
instances remain pinned to the earlier template and continue to verify against
their historical state and receipts.

Migration is explicit:

```text
old timeline state root
  -> pinned migration process
  -> canonical :workspace/build value
  -> signed new timeline instance or accepted workspace commit
```

Historical roots are never rewritten.

## Deliberate current limits

- One contract instance has one linear authoritative head.
- Participants are fixed by initial parameters.
- Current indexes are ordinary HCV0 maps.
- Step and checkpoint records are specified but not yet separate timeline events.
- The reducer records receipt roots but does not yet derive capabilities or
  execute host effects.
- It does not define document OT, scene merge, DOM merge or AI orchestration
  policy.

Multi-parent workspace commits and scoped refs are tracked in
[#13](https://github.com/greenways-ai/ignatius/issues/13). HPT0 indexes,
structural merge programs, portable execution and capability records remain
separate phases so none destabilises the existing ledger.
