# Agent workflows over Git and object storage

Ignatius is a signed coordination and provenance plane for collaborative agent
work. It is not intended to replace Git, R2, S3, a local filesystem, or a
document store.

The working division is:

```text
Git
  source code, text documents, branches, commits, diffs and merges

R2 / S3 / local storage
  model outputs, logs, media, binaries, checkpoints and large bundles

Ignatius
  exact resource pins, work dependencies, agent claims, process state,
  checkpoints, reviews, accepted workspace heads, signatures and receipts
```

This keeps the linear ledger compact. A transaction records that an agent
performed one signed transition against exact inputs; it does not copy a whole
repository or large artifact into the global state.

## What Ignatius already provides

Ignatius currently supplies the components needed beneath an agent workflow
tracker:

- immutable HCV1 values and labelled `CellRef` edges;
- verified block loading and immutable block writes;
- scoped compare-and-set refs in memory and PostgreSQL;
- signed account sequencing, transaction admission and receipts;
- canonical process definitions, runs, steps and checkpoints;
- artifact identities and immutable artifact versions;
- a signed timeline reducer;
- multi-parent workspace commits;
- personal branches, proposals, reviews, accepted `main` and releases; and
- rebuildable PostgreSQL projections over canonical values.

`ignatius.workflow` composes those pieces into the first task-oriented API. It
does not introduce another storage engine or another commit graph.

## External resource versions

An external resource version is represented with the existing canonical
`:artifact/version` record.

For a Git branch:

```clojure
{:action :resource/register
 :workspace/id "greenways/ignatius"

 :resource/id
 "git/greenways-ai/ignatius/refs/heads/agent/docs"

 :resource/kind :git/commit
 :resource/provider :git

 :resource/version
 "47e64139840644d92487e311065fb845d72a2b33"

 :resource/previous-version
 "909e5041ba45505ecfc29f25e547f04a6b6246d0"

 :resource/parent-versions
 ["909e5041ba45505ecfc29f25e547f04a6b6246d0"]

 :resource/locator
 {:git/repository "greenways-ai/ignatius"
  :git/ref "refs/heads/agent/docs"
  :git/tree "tree-object-id"}

 :resource/digest-algorithm :git/sha1
 :resource/digest
 "47e64139840644d92487e311065fb845d72a2b33"

 :process/id "work/docs"}
```

The stable resource ID names an external ref or logical object. The version pins
one exact immutable revision. Different Git branches use different resource IDs,
so sibling commits do not overwrite each other.

For object storage:

```clojure
{:action :resource/register
 :workspace/id "greenways/ignatius"

 :resource/id "r2/greenways-builds/render/main"
 :resource/kind :storage/object
 :resource/provider :r2
 :resource/version "sha256:..."
 :resource/previous-version "sha256:..."

 :resource/locator
 {:storage/bucket "greenways-builds"
  :storage/key "render/main.glb"
  :storage/version-id "provider-version-id"}

 :resource/digest-algorithm :sha256
 :resource/digest "..."
 :resource/size 18423192

 :process/id "work/render"}
```

Credentials, bearer tokens and signed download URLs must never be placed in the
canonical locator. The host adapter resolves those from its own capability
configuration.

## Work items

A work item reuses the canonical `:process/run` record. The workflow extension
adds dependency, assignment and exact resource-reference fields without
inventing a parallel task representation.

```clojure
{:action :work/create
 :workspace/id "greenways/ignatius"

 :work/id "work/docs"
 :work/kind :code/change
 :work/title "Document the agent workflow"
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

The lifecycle is:

```text
:open
  -> :work/claim
:claimed
  -> :work/start
:running
  -> :work/checkpoint
  -> :resource/register
  -> :work/complete
:complete
```

A claim is accepted only when every dependency is complete. Only the verified
claiming signer can start, checkpoint or complete the work.

Completion requires every output resource to:

1. exist as an exact registered version;
2. belong to the same workspace; and
3. identify the completing work item as its producer.

This gives a direct, signed answer to:

```text
Which agent did this?
What exact code and artifacts did it start from?
Which task dependencies were complete?
What checkpoints and tool receipts were produced?
Which Git commit or stored object was the final output?
```

## Checkpoints

A checkpoint reuses `:process/checkpoint`:

```clojure
{:action :work/checkpoint
 :workspace/id "greenways/ignatius"
 :work/id "work/docs"

 :checkpoint/id "checkpoint/docs/1"
 :checkpoint/state-root working-state-root
 :checkpoint/resource-references
 [draft-commit-reference]
 :checkpoint/receipt-root tool-receipt-root
 :checkpoint/metadata
 {:message "Draft complete; examples still need validation"}}
```

Checkpoints do not advance an accepted Git branch or workspace `main`. They are
signed durable observations that an agent or recovery process can use to resume.

## Git host adapter

The repository includes `scripts/ignatius-git-event`. It reads a local Git
checkout and emits an unsigned canonical event payload. The normal Ignatius
client then signs and submits that payload.

Register the current commit as the initial selected version of a branch:

```sh
scripts/ignatius-git-event resource \
  --workspace greenways/ignatius \
  --resource-id git/greenways-ai/ignatius/refs/heads/main \
  --repo . \
  --initial
```

Register a commit produced by one running work item:

```sh
scripts/ignatius-git-event resource \
  --workspace greenways/ignatius \
  --resource-id git/greenways-ai/ignatius/refs/heads/agent/docs \
  --repo . \
  --process-id work/docs
```

Create work pinned to an exact commit:

```sh
scripts/ignatius-git-event work-create \
  --workspace greenways/ignatius \
  --work-id work/docs \
  --kind code/change \
  --title "Document the agent workflow" \
  --definition-root process-definition-root \
  --input \
  git/greenways-ai/ignatius/refs/heads/main=909e5041ba45505ecfc29f25e547f04a6b6246d0
```

Other commands emit claim, start, checkpoint and completion payloads:

```sh
scripts/ignatius-git-event work-claim ...
scripts/ignatius-git-event work-start ...
scripts/ignatius-git-event work-checkpoint ...
scripts/ignatius-git-event work-complete ...
```

The adapter refuses a dirty working tree by default. `--allow-dirty` records the
dirty flag but should be used only for checkpoints, never as final provenance.

## Collaborative-agent operating model

A practical orchestrator works as follows:

```text
1. Scheduler reads ready work from an Ignatius projection.
2. Agent signs :work/claim.
3. Agent checks out the exact Git commit in the input reference.
4. Agent signs :work/start.
5. Agent performs local work and writes large outputs to Git or object storage.
6. Agent periodically registers resource versions and signs checkpoints.
7. Agent registers its final Git commit or object-store digest.
8. Agent signs :work/complete with exact output references.
9. Review agents sign review decisions against those exact outputs.
10. Existing workspace policy accepts a proposal into main or publishes release.
```

Git continues to provide file-level merging. Ignatius provides the cross-system
receipt that connects Git commits, object-store artifacts, agent identities,
reviews and accepted workspace state.

## Deliberate limits of the first slice

The first implementation does not yet:

- clone or fetch repositories inside the deterministic VM;
- verify remote Git signatures or object-store bytes inside PostgreSQL;
- schedule agents or manage leases and heartbeats;
- translate GitHub issues and pull requests automatically;
- provide search projections for ready, blocked and overdue work;
- grant ambient filesystem, network or storage authority; or
- define automatic conflict resolution for agent-produced files.

Those are host and projection layers. The canonical reducer remains deterministic
and provider-neutral.

## Next implementation slices

1. Add PostgreSQL projections for work status, assignee, dependencies, resources
   and latest checkpoints.
2. Add a GitHub webhook/Actions adapter that maps issues, branches, PRs, checks
   and reviews onto exact Ignatius work and resource records.
3. Add capability-scoped resource verification for Git, R2, S3 and local stores.
4. Add claim leases, heartbeats, cancellation and reassignment.
5. Add scheduler/outbox APIs for ready work.
6. Connect accepted work outputs to the existing proposal, review, `main` and
   release lifecycle.
7. Move large work/resource indexes to HPT1 when the measured crossover warrants
   it.
