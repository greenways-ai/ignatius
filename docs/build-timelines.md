# Signed build timelines

`ignatius.timeline` is the first process-graph slice for Ignatius. It is a pure
reducer contract that records a signed, deterministic build history using the
existing contract publication, expected-head, commit and receipt machinery.

The module is intentionally generic. The same contract can track an AI run, a
scene or DOM build, a document workflow, a software release, or a mixed process
that produces several kinds of immutable artifacts.

## Why this is the first slice

Ignatius already injects trusted event fields and commits every accepted reducer
transition:

```text
signed transaction
  -> verified signer, transaction, timestamp and previous head
  -> pure apply-event
  -> immutable contract state and commit roots
  -> transaction receipt over previous and resulting global state
```

That is enough to prove useful process and provenance semantics without first
adding a new storage codec, a multi-parent commit DAG, or a portable VM.

## State model

The contract state separates stable logical identities from exact immutable
content roots:

```clojure
{:record/type :timeline/build
 :timeline/format-version 1

 :timeline/workspace-id "world/orbital-station"
 :timeline/workspace-kind :scene
 :timeline/schema-root scene-schema-root

 :timeline/participants
 {alice true
  bob true}

 :timeline/status :active
 :timeline/processes {}
 :timeline/artifacts {}
 :timeline/reviews {}}
```

A process run is addressed by a stable `:process/id` and pins its exact
definition, inputs, outputs and execution receipt:

```clojure
{:record/type :timeline/process-run
 :process/id "lighting-pass-17"
 :process/definition-root lighting-agent-definition-root
 :process/input-roots [scene-root-A prompt-root]
 :process/parent-runs ["layout-pass-9"]
 :process/status :complete
 :process/output-roots [scene-root-B]
 :process/result-root result-root
 :process/receipt-root model-and-tool-receipt-root
 :process/started verified-start-provenance
 :process/completed verified-completion-provenance}
```

An artifact entry maps a stable ID to one exact version:

```clojure
{:record/type :timeline/artifact-version
 :artifact/id "scene/main"
 :artifact/kind :scene
 :artifact/root scene-root-B
 :artifact/previous-root scene-root-A
 :artifact/parent-roots [scene-root-A]
 :artifact/process-id "lighting-pass-17"
 :artifact/schema-root scene-schema-root
 :artifact/metadata {:label "Lighting pass"}
 :artifact/published verified-publication-provenance}
```

The old root remains immutable and reachable through the event and contract
history. Updating the stable artifact ID requires the caller to supply the exact
current `:artifact/previous-root`; a stale value is rejected.

## Events

### Start a process

```clojure
(contract/submit timeline
  {:action :process/start
   :process/id "lighting-pass-17"
   :process/definition-root lighting-agent-definition-root
   :process/input-roots [scene-root-A prompt-root]
   :process/parent-runs ["layout-pass-9"]})
```

The run ID cannot be reused. The reducer records ledger-derived provenance
rather than trusting signer or time fields supplied by the payload.

### Publish an artifact version

```clojure
(contract/submit timeline
  {:action :artifact/publish
   :artifact/id "scene/main"
   :artifact/kind :scene
   :artifact/root scene-root-B
   :artifact/previous-root scene-root-A
   :artifact/parent-roots [scene-root-A]
   :artifact/schema-root scene-schema-root
   :artifact/metadata {:label "Lighting pass"}
   :process/id "lighting-pass-17"})
```

For an artifact's first version, `:artifact/previous-root` is `nil`. Subsequent
updates must name the exact current root.

### Record a review

```clojure
(contract/submit timeline
  {:action :review/record
   :review/id "review/scene-B/alice"
   :review/decision :approve
   :review/evidence-root review-notes-root
   :artifact/id "scene/main"
   :artifact/root scene-root-B})
```

A review is pinned to the current exact artifact root. A review of an obsolete
root is rejected rather than silently applying to a later version.

### Complete a process

```clojure
(contract/submit timeline
  {:action :process/complete
   :process/id "lighting-pass-17"
   :process/output-roots [scene-root-B]
   :process/result-root result-root
   :process/receipt-root model-and-tool-receipt-root})
```

Only a running process can complete, and completion is immutable.

## Provenance

Every accepted run, artifact version and review stores:

```clojure
{:record/type :timeline/provenance
 :timeline/signer verified-account
 :timeline/transaction signed-transaction-root
 :timeline/timestamp ledger-timestamp
 :timeline/previous-head exact-contract-head}
```

These fields are copied from the contract runtime's verified event. Payload
attempts to claim another signer, timestamp, transaction or predecessor are
overwritten before the reducer executes.

The containing contract commit additionally pins the previous and resulting
state roots. The surrounding transaction receipt proves execution against the
global Ignatius state.

## Domain mappings

### AI processes

- process definition root: exact agent/workflow/model/tool contract;
- inputs: prompt, context, source artifact and capability roots;
- outputs: generated document, scene, code, evaluation or tool-result roots;
- process receipt: model call, tool execution and effect evidence;
- review: human or agent decision against an exact output root.

### Scene graph and DOM builds

- workspace ID: stable world, page or component identity;
- artifact ID: stable scene, DOM, asset or layer name;
- artifact root: exact immutable graph version;
- process run: import, generation, layout, shader, animation or rendering pass;
- parent roots: source versions used to derive the new graph.

Large stable-node indexes and structural merges are separate roadmap work; the
v1 timeline can already pin whole graph roots and their production history.

### Documents as workflows

- artifact root: exact canonical document tree or bundle;
- process run: drafting, transformation, analysis, export or signing step;
- review: approval, rejection or requested changes against one exact version;
- evidence root: comments, policy output, delivery receipt or external proof.

Document editing algorithms, private-room policy and product UX remain in Hestia
or another application. Ignatius supplies the generic signed process and
artifact record underneath them.

## Publication and views

Compile and publish `ignatius.timeline` as an ordinary reducer template with:

```text
init          -> ignatius.timeline/init
apply-event   -> ignatius.timeline/apply-event
views         -> summary, processes, artifacts, reviews
```

An instance is opened with a workspace descriptor and participant map, then
advanced through normal `contract/submit` calls.

## Deliberate v1 limits

- One contract instance has one linear authoritative head.
- Participants are fixed by the initial parameters.
- Process, artifact and review indexes are ordinary HCV1 maps.
- The reducer records supplied execution-receipt roots but does not yet derive
  required capabilities or execute effects.
- It does not define document OT, scene merge, DOM merge or AI orchestration
  policy.

Multi-parent workspace commits and scoped branch refs are tracked in
[#13](https://github.com/greenways-ai/ignatius/issues/13). HPT1 indexes,
structural merge programs, portable execution and signed capability records are
tracked independently so none of them destabilises the existing ledger.
