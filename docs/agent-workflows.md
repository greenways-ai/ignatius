# Agent workflows over Git and external storage

Ignatius is the signed coordination and provenance plane for collaborative
agent work. It complements Git, R2, S3, local filesystems and document stores;
it does not replace them.

```text
Git
  source, text documents, branches, commits, diffs and file-level merges

R2 / S3 / local storage
  model outputs, logs, media, binaries and large checkpoint bundles

Ignatius
  exact resource pins, work dependencies, agent claims, execution state,
  checkpoints, reviews, accepted workspace heads, signatures and receipts
```

A transaction records that an identified agent performed one signed transition
against exact immutable inputs. Repository and artifact bytes remain in the
system designed to store them.

## Existing Ignatius foundation

The workflow layer builds on capabilities already present in Ignatius:

- immutable HCV0 values and labelled `CellRef` edges;
- verified immutable blocks and provider-neutral block/ref contracts;
- linearizable PostgreSQL compare-and-set refs;
- signed account sequencing, admission, blocks and receipts;
- canonical process definitions, runs, steps and checkpoints;
- canonical artifact identities and immutable versions;
- signed build timelines;
- multi-parent workspace commit DAGs;
- personal branches, proposals and reviewer decisions;
- policy-gated accepted `main` and immutable releases; and
- rebuildable PostgreSQL projections.

`ignatius.workflow` composes those records into a task-oriented reducer. It does
not create another process vocabulary, storage engine or commit graph.

## External resource versions

An external resource version reuses the canonical `:artifact/version` record.
A stable resource ID identifies one external ref or logical object, while
`:resource/version` pins one exact immutable version.

```clojure
{:action :resource/register
 :workspace/id "greenways/ignatius"

 :resource/id
 "git/greenways-ai/ignatius/refs/heads/agent/docs"

 :resource/kind :git/commit
 :resource/provider :git

 :resource/version
 "47e64139840644d92487e311065fb845d72a2b33"

 ;; Exact Ignatius CAS expectation for this resource ID.
 ;; Use nil when this is the first selected version.
 :resource/previous-version nil

 ;; Git ancestry is separate from ref-selection history.
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

`resource/previous-version` and `resource/parent-versions` are deliberately
different:

```text
previous version
  the exact version currently selected in Ignatius for this resource ID

parent versions
  immutable derivation ancestry reported by the external store
```

A Git parent must never be guessed to be the current Ignatius ref. Branches can
be created, rebased, force-updated or merged. The host obtains the selected
resource version from Ignatius and supplies it explicitly as the CAS
expectation.

Different Git branches use different resource IDs, allowing sibling agent work
to coexist without overwriting another branch.

An object-store resource follows the same contract:

```clojure
{:action :resource/register
 :workspace/id "greenways/ignatius"

 :resource/id "r2/greenways-builds/render/main"
 :resource/kind :storage/object
 :resource/provider :r2
 :resource/version "sha256:..."
 :resource/previous-version "sha256:..."
 :resource/parent-versions []

 :resource/locator
 {:storage/bucket "greenways-builds"
  :storage/key "render/main.glb"
  :storage/version-id "provider-version-id"}

 :resource/digest-algorithm :sha256
 :resource/digest "..."
 :resource/size 18423192
 :process/id "work/render"}
```

Credentials, bearer tokens and expiring signed URLs must not enter the
canonical locator. The host resolves credentials through its own capabilities.
The Git adapter removes embedded HTTP credentials, query strings and fragments
before emitting an event.

## Work items

A work item reuses `:process/run` and adds workflow fields beneath
`:record/extensions`.

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

The signed lifecycle is:

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

A claim succeeds only after every dependency completes. Only the verified
claiming signer can start, checkpoint or complete the work.

Completion requires every output reference to:

1. resolve to an exact registered resource version;
2. belong to the same workspace; and
3. identify the completing work item as its producer.

The resulting receipt answers:

```text
Which agent performed the work?
Which exact code and artifacts did it start from?
Which dependencies had completed?
Which checkpoints and tool receipts were produced?
Which Git commit or stored object was the final output?
Who reviewed it, and which version was accepted?
```

## Checkpoints

A durable checkpoint reuses `:process/checkpoint`:

```clojure
{:action :work/checkpoint
 :workspace/id "greenways/ignatius"
 :work/id "work/docs"

 :checkpoint/id "checkpoint/docs/1"
 :checkpoint/state-root working-state-root
 :checkpoint/resource-references [draft-commit-reference]
 :checkpoint/receipt-root tool-receipt-root
 :checkpoint/metadata
 {:message "Draft complete; examples still need validation"}}
```

A checkpoint is a signed recovery observation. It does not automatically advance
a Git ref, workspace `main`, proposal or release.

## Git host adapter

`scripts/ignatius-git-event` reads a local checkout and emits an unsigned event
payload. The ordinary Ignatius client signs and submits that payload.

Register the first selected version of a branch:

```sh
scripts/ignatius-git-event resource \
  --workspace greenways/ignatius \
  --resource-id git/greenways-ai/ignatius/refs/heads/main \
  --repo . \
  --initial
```

Advance an already registered resource using the exact version read from
Ignatius, not a guessed Git parent:

```sh
scripts/ignatius-git-event resource \
  --workspace greenways/ignatius \
  --resource-id git/greenways-ai/ignatius/refs/heads/main \
  --repo . \
  --previous-version 909e5041ba45505ecfc29f25e547f04a6b6246d0
```

Register the first commit produced on a new agent branch:

```sh
scripts/ignatius-git-event resource \
  --workspace greenways/ignatius \
  --resource-id git/greenways-ai/ignatius/refs/heads/agent/docs \
  --repo . \
  --process-id work/docs \
  --initial
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
dirty flag and is intended for checkpoints, not final provenance.

## Collaborative-agent operating model

```text
1. Scheduler reads ready work from an Ignatius projection.
2. Agent signs :work/claim.
3. Agent checks out the exact Git commit named by the input reference.
4. Agent signs :work/start.
5. Agent works locally and writes payloads to Git or object storage.
6. Agent registers exact intermediate versions and signs checkpoints.
7. Agent registers the final commit or object digest as produced by its work.
8. Agent signs :work/complete with exact output references.
9. Review agents sign decisions against those exact outputs.
10. Existing workspace policy accepts a proposal into main or publishes release.
```

Git retains file-level collaboration and merge mechanics. Ignatius supplies the
cross-system receipt connecting commits, stored artifacts, agent identities,
work dependencies, reviews and accepted workspace state.

## First-slice limits

The deterministic reducer does not yet:

- clone or fetch repositories;
- verify remote Git signatures or object-store bytes inside PostgreSQL;
- schedule agents or manage leases and heartbeats;
- ingest GitHub issues and pull requests automatically;
- provide ready, blocked, overdue and assignee projections;
- grant ambient filesystem, network or storage authority; or
- resolve file conflicts automatically.

These belong to host adapters, capability grants and rebuildable projections.
They do not belong in canonical reducer primitives.

## Next implementation slices

1. PostgreSQL projections for work status, assignee, dependencies, resources and
   latest checkpoints.
2. Scheduler/outbox APIs for ready work.
3. GitHub webhook and Actions adapters mapping issues, branches, PRs, checks and
   reviews to exact Ignatius records.
4. Capability-scoped verification for Git, R2, S3 and local stores.
5. Claim leases, heartbeats, cancellation, reassignment and checkpoint resume.
6. Automatic creation of workspace proposals from completed output sets, reusing
   the existing review, accepted-main and release lifecycle.
7. HPT0 indexes for large work and resource catalogs once the canonical format
   and crossover rules under issue #14 are complete.
