# GitHub issue adapter for Agent Workflow

This is the first application-facing adapter for Ignatius Agent Workflow. It
maps verified GitHub issue webhooks onto provider-neutral Ignatius resources and
work without making GitHub canonical.

```text
issues.opened
  -> retained canonical issue snapshot
  -> exact immutable resource version
  -> dependency-aware work item pinned to that version

issues.edited / reopened / closed
  -> retained canonical issue snapshot
  -> exact successor resource version
  -> no duplicate work item
```

The adapter does not grant agent authority and does not submit ledger
transactions. The GitHub HMAC proves provider delivery. An authorised Ignatius
client must still sign and submit the emitted events.

## Create work from an issue

```sh
export GITHUB_WEBHOOK_SECRET='...'

python3 scripts/ignatius-github-event issue-opened \
  --workspace greenways/ignatius \
  --repository greenways-ai/ignatius \
  --definition-root definition/github-issue-work-v1 \
  --delivery-id "$X_GITHUB_DELIVERY" \
  --payload webhook.json \
  --signature "$X_HUB_SIGNATURE_256" \
  --initial \
  --outbox-db var/ignatius-github.sqlite
```

The output is one deterministic EDN vector. Event 1 registers a
`:github/issue-snapshot` resource. Event 2 creates a work item whose input
reference pins that exact version.

## Retain later issue state

Every later mutable issue state becomes a successor snapshot selected with an
explicit compare-and-set predecessor:

```sh
python3 scripts/ignatius-github-event issue-edited \
  --workspace greenways/ignatius \
  --repository greenways-ai/ignatius \
  --delivery-id "$X_GITHUB_DELIVERY" \
  --payload webhook.json \
  --signature "$X_HUB_SIGNATURE_256" \
  --previous-version sha256:<current-snapshot-digest> \
  --outbox-db var/ignatius-github.sqlite
```

The same shape is available as `issue-reopened` and `issue-closed`. These
commands emit only `:resource/register`; they never recreate the work item.
The original work input therefore remains an immutable record of the request
that created the task, while the workspace resource selection advances through
the issue's later provider states.

Closing a GitHub issue does not automatically complete or cancel signed work.
That is a workspace-policy decision, not provider authority.

## Exact snapshot retention

The version is `sha256:<digest>` over canonical JSON containing stable issue and
repository fields. The issue body affects the digest but is not copied into
ledger display metadata.

When `--outbox-db` is supplied, the same transaction stores:

```text
github_snapshot
  canonical snapshot bytes keyed by exact version

github_delivery
  provider delivery ID, raw-body digest and emitted event vector

github_outbox
  ordered resource/work events pending signed submission
```

This preserves historical provider content after the mutable GitHub issue
changes. SQLite remains operational host state, not Ignatius canonical truth;
the snapshot may later be replicated to Tahto, R2, S3 or another
capability-scoped store.

## Authority boundary

```text
GitHub webhook signature
  proves GitHub delivered these exact bytes

snapshot digest
  identifies the exact provider content retained by the adapter

Ignatius transaction signature
  authorises resource registration and work creation

workspace policy
  governs claim, execution, review, acceptance and promotion
```

Titles, bodies, labels and mutable GitHub state are request/display data. They
do not bypass claims, capabilities, reviews or accepted-main policy.

## Replay and safety

The adapter:

- verifies `X-Hub-Signature-256` with constant-time comparison;
- rejects malformed signatures and duplicate JSON keys;
- requires an explicit expected repository;
- rejects pull requests from the issue-work path;
- normalises labels and dependency IDs deterministically;
- requires either `--initial` or an exact `--previous-version`;
- atomically deduplicates delivery IDs and queues ordered events;
- rejects a reused delivery ID with different content;
- checks action/state agreement for open, closed and reopened deliveries;
- excludes secrets, installation data and mutable URLs from canonical values.

Run the complete fixture with:

```sh
python3 scripts/test-ignatius-github-event
```

## Exact branch and commit resources

A signed GitHub push delivery identifies the repository, ref, previous provider
head and new provider head. The push payload does not carry the complete Git
commit object, so the host must enrich the delivery with the exact commit object
returned by a capability-scoped GitHub or Git reader.

```sh
python3 scripts/ignatius-github-event push \
  --workspace greenways/ignatius \
  --repository greenways-ai/ignatius \
  --delivery-id "$X_GITHUB_DELIVERY" \
  --payload push-webhook.json \
  --signature "$X_HUB_SIGNATURE_256" \
  --commit-object commit-object.json \
  --process-id github/greenways-ai/ignatius/issues/44 \
  --previous-version <currently-selected-commit> \
  --outbox-db var/ignatius-github.sqlite
```

The adapter requires the enriched commit SHA to equal the signed push `after`
SHA, then pins the exact tree and ordered parent commit IDs. The emitted
`:git/commit` resource contains:

```text
resource/version
  exact Git commit object ID

resource/previous-version
  exact Ignatius resource version expected to be selected before this update

resource/parent-versions
  Git commit parents from the enriched commit object

resource/locator
  repository, full branch ref and exact tree object ID
```

The compare-and-set predecessor and Git ancestry are deliberately different.
On a force push, `:resource/previous-version` remains the old selected branch
head while `:resource/parent-versions` records the actual parents of the new
commit. This preserves both selection history and content ancestry without
pretending that one is the other.

The optional `--process-id` attributes a newly registered output commit to the
running work item that produced it. The canonical workflow reducer will still
require the assignee to sign registration and later completion.

The current slice accepts branch refs only. Branch deletion is provider state,
not a new commit version, and is rejected until a separate ref-deletion policy
is defined.

The `--commit-object` file is a host-capability input. Production operators must
obtain it from an authenticated GitHub API lookup or a verified local Git object
reader for the signed `after` SHA. Arbitrary client-supplied JSON must not be
promoted as provider evidence.

Run the Git resource fixture with:

```sh
python3 scripts/test-ignatius-github-push
```

It covers normal updates, exact tree and parent retention, process attribution,
force pushes, delivery replay, repository binding, deleted/tag/invalid refs,
object-ID width checks, enrichment mismatch, duplicate JSON keys and malformed
HMACs.

## Next slices

- check runs as execution evidence and checkpoints;
- pull requests as workspace proposals;
- attributed and signed review decisions;
- merged output registration and release evidence;
- direct capability-scoped GitHub/Git enrichment without an intermediate file.
