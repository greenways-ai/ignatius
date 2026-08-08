# GitHub issue adapter for Agent Workflow

This is the first application-facing adapter for Ignatius Agent Workflow. It
maps a verified GitHub `issues.opened` webhook onto provider-neutral Ignatius
resource and work events without making GitHub canonical.

```text
verified GitHub delivery
  -> retained canonical issue snapshot
  -> exact immutable resource version
  -> dependency-aware work item pinned to that version
```

The adapter does not grant agent authority and does not submit ledger
transactions. The GitHub HMAC proves provider delivery. An authorised Ignatius
client must still sign and submit the emitted events.

## Run it

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
  position 0: resource registration
  position 1: work creation
```

This preserves the historical provider content after the mutable GitHub issue
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
- excludes secrets, installation data and mutable URLs from canonical values.

Run the complete fixture with:

```sh
python3 scripts/test-ignatius-github-event
```

## Next slices

- issue edits, closure and reopening as new snapshot versions without recreating work;
- branches and commits as exact Git resources;
- check runs as execution evidence and checkpoints;
- pull requests as workspace proposals;
- attributed and signed review decisions;
- merged output registration and release evidence.
