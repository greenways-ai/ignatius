# Ignatius

Ignatius is the **immutable persistence and signed-evidence substrate** for
Greenways. It stores content-addressed blocks, selects roots through scoped
compare-and-set refs, and verifies generic signed evidence and provenance.

It works with Git, Tahto and object storage rather than replacing them:

```text
Git
  source, text documents, branches, commits, diffs and file-level merges

Tahto
  semantic objects, versions, sync, backup and recovery

R2 / S3 / local storage
  model outputs, logs, media, binaries and large checkpoint bundles

Hestia + std.work
  intent, approvals, work dependencies, execution, reviews and releases

Ignatius
  immutable blocks, scoped refs, signed evidence, provenance and receipts
```

Ignatius does not require a token, public activity feed or public consensus
network. PostgreSQL is the durable multi-writer adapter; Hara modules define the
portable canonical values, reducers and client semantics.

## Boundary correction

Legacy workflow, workspace, Git and GitHub orchestration still exists in this
repository. It is being migrated to Hestia (`intent`, approval and workflow
policy) and `std.work` (execution and recovery). No new orchestration behaviour
should be added to Ignatius during that migration. Compatible record decoders
may remain while stored histories are upgraded.

The generic storage and evidence contracts remain authoritative. An ordinary
semantic edit may use Ignatius blocks and refs without becoming a workflow or a
global acceptance event.

## Current status

The signed foundation and first workflow slice are implemented:

- canonical process, artifact, checkpoint, review, attestation and evidence
  records;
- immutable HCV1 values and labelled content-addressed edges;
- signed account sequencing, transaction admission, block commitment and
  receipts;
- provider-neutral immutable block storage and scoped compare-and-set refs;
- a Git/external-storage workflow reducer;
- dependency-aware work, agent claims, starts, checkpoints and completion;
- personal workspace branches, proposals and reviewer decisions;
- policy-gated accepted `main` and immutable releases; and
- a Git adapter that emits exact resource and workflow event payloads.

The active delivery track is [Agent Workflow #41](https://github.com/greenways-ai/ignatius/issues/41).
The current implementation phase is [operational projections and scheduler API
#43](https://github.com/greenways-ai/ignatius/issues/43). The end-to-end release
definition is [Agent Workflow v0.1 #48](https://github.com/greenways-ai/ignatius/issues/48).

## Product model

```text
Agent host / scheduler
  │
  ├── checks out exact Git or Tahto inputs
  ├── invokes models and tools under explicit capabilities
  └── writes large outputs to Git or object storage
  │
  ▼
Signed Ignatius workflow event
  │
  ├── exact input and output references
  ├── work definition and dependency roots
  ├── agent identity and account sequence
  ├── checkpoint and execution receipts
  └── optimistic expected-head checks
  │
  ▼
Canonical Hara reducer
  │
  ├── immutable process, artifact and timeline values
  ├── transaction and resulting state roots
  └── signed receipt and linear block
  │
  ▼
Rebuildable projections
  │
  ├── ready and blocked work
  ├── running work by agent
  ├── latest checkpoints and exact resources
  └── proposals, reviews, accepted heads and releases
```

Ignatius owns the signed coordination outcome. Git owns file-level history and
merging. Tahto owns semantic object storage and sync. Object stores own large
payload bytes. Projection tables and caches remain disposable and rebuildable.

## Collaborative workflow

[`ignatius.workflow`](hal/src/ignatius/workflow.hal) composes the existing
canonical record families into a task-oriented reducer.

The lifecycle is:

```text
:open
  -> :work/claim
:claimed
  -> :work/start
:running
  -> :resource/register
  -> :work/checkpoint
  -> :work/complete
:complete
```

A work item is a canonical `:process/run`. An external Git commit or object-store
version is a canonical `:artifact/version`. Inputs and outputs use exact
`:reference/logical` pins. Every accepted transition is also a signed
`:timeline/entry` with `:ledger/evidence`.

Only the verified assignee can start, checkpoint or complete claimed work.
Dependencies must be complete before downstream work can be claimed. Completion
requires every output to exist and identify the completing work item as its
producer.

### Create work pinned to an exact Git commit

```clojure
{:action :work/create
 :workspace/id "greenways/ignatius"

 :work/id "work/docs"
 :work/kind :code/change
 :work/title "Document the agent workflow"

 ;; Intended to pin an exact canonical std.work specification.
 :work/definition-root process-definition-root

 :work/dependency-ids ["work/runtime"]
 :work/input-references
 [{:record/type :reference/logical
   :record/version 1
   :record/extensions {}
   :reference/scope-id "greenways/ignatius"
   :reference/kind :resource/version
   :reference/id "git/greenways-ai/ignatius/refs/heads/main"
   :reference/root base-commit
   :reference/metadata {}}]}
```

### Claim and start

```clojure
{:action :work/claim
 :workspace/id "greenways/ignatius"
 :work/id "work/docs"}

{:action :work/start
 :workspace/id "greenways/ignatius"
 :work/id "work/docs"}
```

The signed claim fixes the assignee. The signed start fixes the exact execution
boundary and ledger evidence.

### Register an output commit

```clojure
{:action :resource/register
 :workspace/id "greenways/ignatius"

 :resource/id
 "git/greenways-ai/ignatius/refs/heads/agent/docs"
 :resource/kind :git/commit
 :resource/provider :git

 :resource/version commit-B

 ;; Exact version currently selected by Ignatius for this resource ID.
 :resource/previous-version nil

 ;; External derivation ancestry, kept separate from the CAS expectation.
 :resource/parent-versions [commit-A]

 :resource/locator
 {:git/repository "greenways-ai/ignatius"
  :git/ref "refs/heads/agent/docs"
  :git/tree tree-B}

 :resource/digest-algorithm :git/sha1
 :resource/digest commit-B
 :process/id "work/docs"}
```

A Git parent is not assumed to be the previously selected Ignatius version.
Branches, merges, rebases and force updates can make those values differ.

### Checkpoint and complete

```clojure
{:action :work/checkpoint
 :workspace/id "greenways/ignatius"
 :work/id "work/docs"
 :checkpoint/id "checkpoint/docs/1"
 :checkpoint/state-root working-state-root
 :checkpoint/resource-references [draft-commit-reference]
 :checkpoint/receipt-root tool-receipt-root}

{:action :work/complete
 :workspace/id "greenways/ignatius"
 :work/id "work/docs"
 :work/output-references [final-commit-reference]
 :work/result-root result-root
 :work/receipt-root execution-receipt-root}
```

## Scheduler query law

[`ignatius.workflow-query`](hal/src/ignatius/workflow_query.hal) defines the
portable classification used by operational projections and schedulers.
Projection builders supply explicitly ordered work and checkpoint IDs, then the
same Hara functions classify them as:

```text
:ready
:blocked
:claimed
:running
:complete
:missing
```

```clojure
(query/scheduler-snapshot
  workspace-state
  ["work/runtime" "work/docs" "work/review"]
  ["checkpoint/runtime/1" "checkpoint/docs/1"])
```

The returned snapshot contains compact work summaries, unresolved dependency
IDs, exact input/output references, assignees, evidence and latest checkpoints.
PostgreSQL projections will materialise these views without becoming canonical
truth.

## Git host adapter

[`scripts/ignatius-git-event`](scripts/ignatius-git-event) reads a local Git
checkout and emits an unsigned EDN payload. The ordinary Ignatius client signs
and submits it.

Register the first selected version of a branch:

```sh
scripts/ignatius-git-event resource \
  --workspace greenways/ignatius \
  --resource-id git/greenways-ai/ignatius/refs/heads/main \
  --repo . \
  --initial
```

Advance an existing resource using the exact selected version read from
Ignatius:

```sh
scripts/ignatius-git-event resource \
  --workspace greenways/ignatius \
  --resource-id git/greenways-ai/ignatius/refs/heads/main \
  --repo . \
  --previous-version f05df74fbebb517b679d122eeb5f6e6635da10c2
```

Create work from an exact commit:

```sh
scripts/ignatius-git-event work-create \
  --workspace greenways/ignatius \
  --work-id work/docs \
  --kind code/change \
  --title "Document the agent workflow" \
  --definition-root process-definition-root \
  --input \
  git/greenways-ai/ignatius/refs/heads/main=f05df74fbebb517b679d122eeb5f6e6635da10c2
```

Other commands emit claim, start, checkpoint and completion payloads:

```sh
scripts/ignatius-git-event work-claim ...
scripts/ignatius-git-event work-start ...
scripts/ignatius-git-event work-checkpoint ...
scripts/ignatius-git-event work-complete ...
```

The adapter rejects dirty working trees by default and removes embedded HTTP
credentials, query strings and fragments from canonical remote locators.

## Acceptance and release

The existing workspace lifecycle provides:

```text
personal branch
  -> immutable proposal
  -> reviewer-specific signed decisions
  -> selected policy/main
  -> policy-gated accepted main
  -> immutable release
```

A completed work item does not automatically become accepted. The remaining
Agent Workflow release train connects exact completed output sets to that
existing proposal, review, main and release law.

See:

- [`docs/workspace-proposals.md`](docs/workspace-proposals.md)
- [`docs/workspace-reviews.md`](docs/workspace-reviews.md)
- [`docs/workspace-main-admission.md`](docs/workspace-main-admission.md)
- [`docs/workspace-release-admission.md`](docs/workspace-release-admission.md)

## Canonical records

[`ignatius.record`](hal/src/ignatius/record.hal) defines versioned ordinary HCV1
values for signed builds:

```text
workspace/build
process/definition · process/run · process/step · process/checkpoint
artifact/identity · artifact/version
reference/logical · timeline/entry · workspace/commit-candidate
review/decision · attestation/claim
execution/provenance · ledger/evidence
```

Every value has a pinned envelope:

```clojure
{:record/type :artifact/version
 :record/version 1
 :record/extensions {}
 ...}
```

Stable IDs and immutable roots remain distinct. Logical edges may use stable IDs
while exact inputs, outputs, reviews and acceptance decisions pin immutable
roots.

See [`docs/canonical-records.md`](docs/canonical-records.md).

## Storage and ledger

[`ignatius.storage`](hal/src/ignatius/storage.hal) separates immutable blocks,
scoped mutable refs and backend capability declarations.

PostgreSQL maps HCV1 values to `Cell` and ordered `CellRef` rows, implements
linearizable compare-and-set refs, verifies signed account sequences, executes
reducers, commits the global linear block and produces transaction receipts.

The generic ref table does not replace account sequences, contract heads or the
network head. Candidate blocks and commits remain immutable even when a ref
update loses a concurrency race.

See [`docs/storage-contracts.md`](docs/storage-contracts.md).

## Performance boundary

The checked-in HCV1 flat-map evidence covers 16, 64, 256, 1,024 and 4,096-entry
maps through PostgreSQL/JDBC.

Small hot maps are suitable for workflow heads and compact state. Large flat maps
show linear lookup and whole-map rewrite costs: at 4,096 entries, construction
and immutable assoc take roughly 17 seconds in the measured environment.

Therefore:

```text
small canonical workflow heads
  HCV1 maps

large work/resource catalogs
  rebuildable PostgreSQL projections now
  HPT1 canonical indexes under issue #14
```

Evidence: [`benchmarks/hpt1-flat-map/evidence.edn`](benchmarks/hpt1-flat-map/evidence.edn)

## Hara and `std.work`

The intended execution relationship is:

```text
std.work
  exact replayable work and checkpointed-step specification

work/definition-root
  immutable root of that exact specification

agent host / portable VM
  executes under explicit capabilities

Ignatius
  records signed inputs, checkpoints, effects, outputs and receipts
```

Ignatius does not grant ambient authority because code names a function. Git,
network, model and object-store effects must be performed by a host with an
explicit capability and bound to execution evidence.

## Build and test

The repository uses pinned Hara and Foundation revisions from `versions.edn`.

```sh
make setup
make db-sql
make db-contracts
make hal-check
make hal-test
make extension-sha-test
```

The complete reproducibility gate is:

```sh
make verify
```

CI also tests the Git workflow adapter and rejects Hestia application namespaces
from entering Ignatius source, generated SQL or generated contracts.

## Repository layout

- `hal/` — portable codecs, records, reducers, workflow queries and clients
- `db/` — PostgreSQL ledger DSL, generated SQL, projections and client contracts
- `scripts/` — host adapters such as the Git event emitter
- `examples/` — executable Hara and ledger demos
- `extensions/` — optional cryptography and proof extensions
- `docs/` — protocol, workflow and integration specifications
- `benchmarks/` — committed reproducible evidence
- `versions.edn` — pinned upstream source revisions

## Delivery roadmap

The focused product train is:

1. [#43 — operational projections and scheduler API](https://github.com/greenways-ai/ignatius/issues/43)
2. [#44 — GitHub issue, branch, PR and review adapter](https://github.com/greenways-ai/ignatius/issues/44)
3. [#45 — capability-scoped Git and object-store verification](https://github.com/greenways-ai/ignatius/issues/45)
4. [#46 — leases, outbox scheduling and checkpoint recovery](https://github.com/greenways-ai/ignatius/issues/46)
5. [#47 — completed outputs through proposal, main and release](https://github.com/greenways-ai/ignatius/issues/47)
6. [#48 — ship Agent Workflow v0.1](https://github.com/greenways-ai/ignatius/issues/48)

Parallel architecture tracks remain in the main [roadmap
#9](https://github.com/greenways-ai/ignatius/issues/9): HPT1 indexes,
content-addressed Hara definitions, portable execution, structural merge,
projection retention and explicit capabilities.

## Application boundary

Ignatius deliberately excludes:

- agent profiles, mandates and product-specific authority policy;
- private rooms, invitations, membership and negotiation;
- document editor behavior and product UX;
- storage credentials and expiring provider URLs;
- ambient network, filesystem, Git or model authority;
- product services and user interfaces.

Applications such as Hestia and Greenways OS own those experiences while
committing canonical workflow evidence and accepted lifecycle changes through
Ignatius.

## Provenance

The initial source was filtered with history from `greenways-ai/hestia` at
`62a0cf9c658e9f81c91d3ef16b0f9b3380f0b33c`. See [`MIGRATION.md`](MIGRATION.md).

## License

Apache License 2.0.
