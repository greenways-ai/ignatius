# Canonical build records

`ignatius.record` defines the application-neutral Hara values used to describe a
complete build: workspaces, process definitions and runs, steps, checkpoints,
artifacts, reviews, attestations, execution provenance and commit candidates.

These records are ordinary HCV1 maps and vectors. This specification introduces
no replacement codec, no DAG-CBOR migration and no change to historical roots.
The root of the canonical Hara value remains the exact identity of one record.

Tracking issue: [#11](https://github.com/greenways-ai/ignatius/issues/11).

## Record envelope

Every v1 record has the same three envelope fields:

```clojure
{:record/type :artifact/version
 :record/version 1
 :record/extensions {}
 ...}
```

- `:record/type` selects one published record family.
- `:record/version` selects the field contract within that family.
- `:record/extensions` contains application-defined namespaced fields.

Constructors pin the type and version. A caller cannot change them by supplying
its own envelope values.

```clojure
(record/workspace-build
  {:record/type :spoofed/type
   :record/version 99
   :workspace/id "workspace/demo"
   :workspace/kind :document})

;; => {:record/type :workspace/build
;;     :record/version 1
;;     ...}
```

## Stable IDs and immutable roots

Ignatius deliberately uses both stable logical identities and exact immutable
roots.

```text
artifact ID:   scene/main
content root:  scene-root-B
```

The stable ID means “the conceptual main scene”. The content root means “this
exact immutable version of that scene”. After another accepted build:

```text
scene/main -> scene-root-C
```

`scene-root-B` remains valid and retrievable.

The naming rules are:

| Field suffix | Meaning |
| --- | --- |
| `/id` | Stable logical identity within an explicit scope |
| `/root` | One exact immutable HCV1, code, schema, receipt or artifact root |
| `/roots` | Ordered vector of exact roots |
| `/reference` | A `:reference/logical` record containing a stable ID and optional exact root |

Fields that expose both forms use both names:

```clojure
{:artifact/producer-run-id "run/lighting-17"
 :artifact/producer-run-root nil}
```

The stable run ID is available immediately. The exact run root may be attached
when the producing record has been materialised and pinned.

## Logical references and cycles

A Merkle storage graph cannot contain direct content-addressed cycles. Logical
scene, DOM, document and workflow relationships may still be cyclic, so they use
stable references:

```clojure
{:record/type :reference/logical
 :record/version 1
 :reference/scope-id "world/orbital-station"
 :reference/kind :scene/entity
 :reference/id "entity/door-7"
 :reference/root nil
 :reference/metadata {}
 :record/extensions {}}
```

A resolver selects an accepted index or workspace head and maps the stable ID to
its current root. A non-nil `:reference/root` pins one exact version:

```clojure
{:reference/id "scene/main"
 :reference/root "scene-root-B"}
```

The logical graph can therefore contain cycles while the immutable storage graph
remains acyclic.

## Canonical defaults

Writers emit every known v1 field. Optional collections have one canonical empty
representation:

```clojure
[]  ; optional ordered collection
{}  ; optional map or metadata collection
nil ; optional scalar, stable ID or exact root
```

Omission and `nil` are not treated as interchangeable writer outputs. This makes
independent implementations more likely to produce the same HCV1 root.

For example, a newly started run contains:

```clojure
{:run/output-roots []
 :run/result-root nil
 :run/receipt-root nil
 :run/completed-evidence nil
 :run/metadata {}}
```

## Unknown fields and extensions

The v1 policy is:

```clojure
:unknown-fields :preserve
:extensions     :namespaced-map
```

A generic reader must retain unknown fields when it stores, signs, forwards or
returns a record. `record/validate-record` returns the original value unchanged
on success, including unknown fields.

Writers should put application additions beneath `:record/extensions`:

```clojure
{:record/extensions
 {:hestia/document-policy-root policy-root
  :worlds/preview-root preview-root}}
```

Unknown top-level fields are still root-significant and must not be silently
removed by a generic relay. Reconstructing an old record through a newer
constructor is a deliberate rewrite and may produce a different root.

## Ledger-derived evidence

Signed contract events reserve these payload fields:

```clojure
[:signer
 :transaction
 :timestamp
 :previous-head
 :contract
 :template]
```

The contract runtime supplies or overwrites them before the reducer executes.
`record/ledger-evidence-from-event` copies only those verified fields:

```clojure
{:record/type :ledger/evidence
 :record/version 1
 :ledger/signer verified-account
 :ledger/transaction-root transaction-root
 :ledger/timestamp ledger-timestamp
 :ledger/previous-head-root previous-contract-head
 :ledger/contract-root contract-root
 :ledger/template-root template-root
 :ledger/global-state-root nil
 :record/extensions {}}
```

The containing contract commit proves the prior and resulting contract state.
The transaction receipt proves execution against the prior and resulting global
Ignatius state. `:ledger/global-state-root` is optional inside a domain record
because it may be attached from the surrounding receipt rather than duplicated
inside every event.

Constructing a `:ledger/evidence` map does not itself verify a signature. Trust
comes from the signed admission and execution path that supplied the fields.

## V1 record catalog

| Record type | Purpose | Required fields |
| --- | --- | --- |
| `:workspace/build` | Stable build/workspace identity and current signed indexes | `:workspace/id`, `:workspace/kind` |
| `:process/definition` | Exact executable process contract | `:process/id`, `:process/kind`, `:process/operation-root` |
| `:process/run` | One execution of an exact process definition | `:run/id`, `:run/definition-root`, `:run/status` |
| `:process/step` | One explicit checkpointable or effectful step | `:step/id`, `:step/run-id`, `:step/definition-root`, `:step/status` |
| `:process/checkpoint` | Durable process or step boundary | `:checkpoint/id`, `:checkpoint/run-id`, `:checkpoint/state-root` |
| `:artifact/identity` | Stable artifact identity within a workspace | `:artifact/id`, `:artifact/workspace-id`, `:artifact/kind` |
| `:artifact/version` | One exact immutable artifact version | `:artifact/id`, `:artifact/content-root` |
| `:reference/logical` | Stable logical edge with optional exact pin | `:reference/scope-id`, `:reference/kind`, `:reference/id` |
| `:timeline/entry` | Reverse-linked accepted build transition | `:timeline/id`, `:timeline/event`, `:timeline/evidence` |
| `:workspace/commit-candidate` | One- or multi-parent proposed workspace state | `:workspace/id`, `:commit/parent-roots`, `:commit/state-root` |
| `:review/decision` | Signed decision against an exact subject root | `:review/id`, `:review/subject-root`, `:review/decision`, `:review/recorded-evidence` |
| `:attestation/claim` | Signed claim with evidence and optional validity scope | `:attestation/id`, `:attestation/claim`, `:attestation/subject-root`, `:attestation/issuer-evidence` |
| `:execution/provenance` | Exact source, compiler, runtime, artifact, I/O and receipt provenance | `:provenance/code-root`, `:provenance/compiler-root`, `:provenance/runtime-root` |
| `:ledger/evidence` | Verified signer and ledger-ordering facts | `:ledger/signer`, `:ledger/timestamp` |

The executable catalog is `ignatius.record/schema-catalog`.

## Root and reference semantics

### Workspace records

```clojure
{:workspace/id stable-workspace-id
 :workspace/schema-root exact-schema-root
 :workspace/entrypoints
 {:edit-reducer exact-code-root
  :merge exact-code-root}
 :workspace/processes {stable-run-id process-run-value}
 :workspace/artifacts {stable-artifact-id artifact-version-value}}
```

The current v1 indexes are ordinary HCV1 maps. They are suitable for the first
useful product slice. HPT1 remains a separate measured optimisation.

### Process definitions and runs

```clojure
{:process/id stable-process-id
 :process/operation-root exact-code-root
 :process/dependency-roots [exact-definition-root ...]
 :process/required-capability-roots [exact-capability-root ...]}
```

A run pins the definition root actually executed:

```clojure
{:run/id stable-run-id
 :run/definition-root exact-process-definition-root
 :run/parent-references [logical-run-reference ...]
 :run/input-roots [exact-input-root ...]
 :run/output-roots [exact-output-root ...]
 :run/receipt-root exact-execution-receipt-root}
```

Parent relationships are logical references because process graphs may refer to
runs across evolving workspaces. An optional reference root can pin a particular
parent version.

### Steps and checkpoints

A process definition describes replayable workflow structure. A step describes
an explicit boundary for time, randomness, model calls, files, network, secrets,
GPU access or other host effects.

```clojure
{:step/run-id stable-run-id
 :step/run-root optional-exact-run-root
 :step/definition-root exact-step-definition-root
 :step/receipt-root exact-step-receipt-root}
```

A checkpoint pins the state and outputs after one completed boundary:

```clojure
{:checkpoint/run-id stable-run-id
 :checkpoint/step-id stable-step-id
 :checkpoint/state-root exact-state-root
 :checkpoint/output-roots [exact-output-root ...]}
```

This vocabulary does not require the current PostgreSQL runtime to become a DBOS
clone. It gives later durable-work execution a canonical evidence format.

### Artifacts

An identity describes the conceptual artifact. A version describes exact bytes or
an exact Hara graph:

```clojure
{:artifact/id "scene/main"
 :artifact/content-root "scene-root-B"
 :artifact/previous-content-root "scene-root-A"
 :artifact/source-roots ["texture-root" "prompt-root"]
 :artifact/producer-run-id "run/lighting-17"
 :artifact/producer-run-root nil}
```

`:artifact/previous-content-root` is immediate accepted version ancestry.
`:artifact/source-roots` are derivation inputs. They are intentionally different.

### Timeline entries

```clojure
{:timeline/id transaction-root
 :timeline/previous-entry-id previous-transaction-root
 :timeline/event artifact-version-value
 :timeline/evidence ledger-evidence-value
 :timeline/subject-reference logical-artifact-reference}
```

The first implementation uses a reverse-linked map rather than vector append.
Following `:timeline/previous-entry-id` from the workspace's latest entry yields
the accepted build history in reverse order.

### Commit candidates

```clojure
{:workspace/id stable-workspace-id
 :commit/parent-roots [left-commit-root right-commit-root]
 :commit/state-root exact-workspace-state-root
 :commit/merge-base-root exact-base-commit-root
 :commit/merge-policy-root exact-code-root}
```

This is a value contract for the later workspace commit DAG. It does not make the
global Ignatius ledger branchable.

### Reviews and attestations

Reviews are decisions against exact subject roots. Attestations are more general
claims and may include a validity interval, audience, scope or revocation root.

```clojure
{:review/subject-id "scene/main"
 :review/subject-root "scene-root-B"
 :review/decision :approve}

{:attestation/claim :artifact/reviewed
 :attestation/subject-id "scene/main"
 :attestation/subject-root "scene-root-B"
 :attestation/revokes-root nil}
```

A later artifact version does not change the subject of an existing review or
attestation.

### Execution provenance

```clojure
{:provenance/source-root source-root
 :provenance/expanded-root expanded-root
 :provenance/code-root semantic-code-root
 :provenance/namespace-root namespace-commit-root
 :provenance/compiler-root compiler-root
 :provenance/runtime-root runtime-root
 :provenance/artifact-root wasm-artifact-root
 :provenance/input-roots [input-root ...]
 :provenance/output-roots [output-root ...]
 :provenance/receipt-root receipt-root}
```

The semantic code root remains identity. A Wasm, bytecode or native artifact is a
rebuildable optimisation tied to exact compiler and runtime provenance.

## AI, scene/DOM and document examples

### AI build

```text
process definition  exact agent/model/tool contract
process run         prompt and context roots -> output roots
step                one model or tool call
checkpoint          durable completed boundary
artifact version    generated code, image, document or scene
review              human or agent decision against exact output
attestation         claim tied to evidence and receipt roots
```

### Scene or DOM build

Scene entities and DOM nodes remain domain Hara values. Their parent, constraint
or reference fields use stable logical references where cycles are possible. A
workspace artifact root pins the exact complete graph or index version.

### Document workflow

A document tree is an artifact. Drafting, transformation, analysis, approval,
export and delivery are process runs and steps. Ignatius supplies generic record,
signature and receipt semantics; Hestia retains private-room policy, editing
algorithms and product UX.

## Conformance vectors

`hal/src/ignatius/record_vectors.hal` publishes one executable v1 example for
every record family. `hal/test/ignatius/record_test.hal` checks:

- envelope pinning;
- default normalisation;
- required-field validation;
- unknown-field preservation;
- stable-ID and exact-root distinctions;
- logical unpinned references;
- artifact ancestry versus source provenance;
- compiler/runtime provenance; and
- multi-parent commit candidates.

The current validator is intentionally shallow. It verifies the record family,
version and required fields. Admission code and future portable runtimes must
also verify referenced roots, signatures, schemas, capabilities and domain rules
at the boundary where those claims become authoritative.

## Versioning

V1 records remain valid indefinitely under HCV1. A future incompatible field
contract uses `:record/version 2` or a new `:record/type`; it does not reinterpret
old roots.

The timeline reducer that emits these records has a new immutable template root.
Existing timeline instances remain pinned to their original template and record
shape. Migration is an explicit process that reads an old state root and produces
a new canonical workspace record and signed successor evidence.
