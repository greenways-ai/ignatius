# GitHub pull-request lifecycle snapshots

`pull-request-lifecycle` retains later mutable GitHub pull-request state as an
exact immutable resource version. It complements `pull-request-proposal`, which
publishes an already verified Ignatius workspace candidate as an immutable
proposal.

```text
pull-request-proposal
  provider snapshot
  + create-only proposal/<candidate-root> intent

pull-request-lifecycle
  successor provider snapshot only
  + no proposal, review, acceptance, completion or release authority
```

The lifecycle command accepts the GitHub `pull_request` actions:

```text
edited
converted_to_draft
closed
reopened
```

Every call requires the exact previous pull-request snapshot version. This
preserves one explicit provider-history chain instead of allowing a later
mutable payload to replace prior evidence.

## Record an update

```sh
export GITHUB_WEBHOOK_SECRET='...'

python3 scripts/ignatius-github-event pull-request-lifecycle \
  --workspace greenways/ignatius \
  --repository greenways-ai/ignatius \
  --delivery-id "$X_GITHUB_DELIVERY" \
  --payload pull-request-webhook.json \
  --signature "$X_HUB_SIGNATURE_256" \
  --candidate-root <verified-ignatius-workspace-commit-root> \
  --origin-root <expected-ignatius-publisher-root> \
  --previous-version sha256:<current-pull-request-snapshot-digest> \
  --outbox-db var/ignatius-github.sqlite
```

The command emits exactly one unsigned `:resource/register` event for the
logical resource:

```text
github/OWNER/REPOSITORY/pulls/NUMBER
```

The new version is the SHA-256 digest of selected canonical JSON. Its
`resource/previous-version` and single `resource/parent-versions` entry both
name the supplied predecessor.

## Retained evidence

The snapshot retains selected stable values needed to interpret later provider
state:

- repository and pull-request numeric and node identities;
- pull-request number, state, draft and merged flags;
- author, title and body;
- created, updated, closed and merged timestamps;
- exact head and base repositories, refs and object IDs;
- optional merge commit object ID;
- selected change counts and mergeability values;
- the verified Ignatius candidate and expected proposal origin; and
- the exact lifecycle action.

Title and body bytes contribute to the snapshot digest and remain in the
operational snapshot store. They are not copied into emitted resource metadata.
Installation fields, API URLs, credentials and arbitrary sender data are not
retained.

The emitted metadata exposes only bounded provider identity and lifecycle
fields, exact Git object IDs, the candidate/proposal binding and the snapshot
format marker `:pull-request-lifecycle-v1`.

## State validation

The adapter rejects contradictory provider state rather than normalising it:

- open pull requests cannot be merged and cannot have closed or merged times;
- closed pull requests must have a close time;
- merged pull requests must have a merge time;
- unmerged pull requests cannot have a merge time;
- `converted_to_draft` requires an open draft pull request;
- `closed` requires `state=closed`; and
- `reopened` requires an open, unmerged pull request.

Git object IDs remain width-consistent across head, base and optional merge
commit values. The pull-request number and base repository must agree with the
signed webhook envelope.

## Merged closure is evidence, not acceptance

A `closed` webhook with `merged=true` proves only that GitHub reported this
provider state in the exact signed payload. The lifecycle adapter does not:

```text
complete Ignatius work
create or approve a review
advance workspace main
register an accepted external head
publish a release
```

Those transitions still require their existing canonical signatures, policy,
compare-and-set expectations and receipts. The merged snapshot is the provider
evidence needed by the later external-output registration slice; it is not a
substitute for that slice.

## Replay and durability

When `--outbox-db` is supplied, snapshot bytes, delivery identity and the one
ordered resource event are committed atomically to the existing SQLite ingress
store. Replaying the same delivery returns the same event and creates no second
outbox row. Reusing a delivery ID with different bytes, snapshot identity or
event content is rejected.

Run the fixture with:

```sh
python3 scripts/test-ignatius-github-pull-lifecycle
```

The fixture proves edit, draft, unmerged close, reopen and merged close chains;
exact predecessor retention; payload non-disclosure in emitted metadata;
merged-state evidence; deterministic replay; one-event outbox ordering; and
rejection of malformed state, object IDs, roots, signatures and JSON.
