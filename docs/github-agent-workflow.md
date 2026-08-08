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

## Next slices

- branch and commit snapshots enriched with exact Git tree IDs;
- check runs as execution evidence and checkpoints;
- pull requests as workspace proposals;
- attributed and signed review decisions;
- merged output registration and release evidence.
