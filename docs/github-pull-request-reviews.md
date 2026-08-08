# GitHub pull-request review snapshots

`pull-request-review` retains the exact provider state of a GitHub pull-request
review while preserving Ignatius's signed review boundary.

GitHub review activity arrives through three webhook actions:

```text
submitted
edited
dismissed
```

The adapter converts each verified delivery into one immutable
`:github/pull-request-review-snapshot` resource version. It never constructs a
canonical `:review/decision`, selects a reviewer ref, advances workspace
`main`, completes work or publishes a release.

## Record a submitted review

```sh
export GITHUB_WEBHOOK_SECRET='...'

python3 scripts/ignatius-github-event pull-request-review \
  --workspace greenways/ignatius \
  --repository greenways-ai/ignatius \
  --delivery-id "$X_GITHUB_DELIVERY" \
  --payload pull-request-review.json \
  --signature "$X_HUB_SIGNATURE_256" \
  --candidate-root <published-ignatius-candidate-root> \
  --origin-root <expected-proposal-publisher-root> \
  --initial \
  --outbox-db var/ignatius-github.sqlite
```

A later edit or dismissal names the exact current review snapshot:

```sh
python3 scripts/ignatius-github-event pull-request-review \
  ... \
  --previous-version sha256:<current-review-snapshot-digest>
```

`submitted` must be initial. `edited` and `dismissed` must identify one exact
predecessor. The logical resource remains:

```text
github/OWNER/REPOSITORY/pulls/NUMBER/reviews/REVIEW_ID
```

Every predecessor remains immutable and retrievable.

## Retained evidence

The selected canonical JSON snapshot contains:

- repository, pull-request and review numeric and node identities;
- pull-request state, draft/merged flags and exact head/base refs and object IDs;
- review author identity, association, body, state, commit object ID and
  submitted time;
- the actor responsible for the webhook action;
- the published candidate and expected proposal origin; and
- the exact webhook action.

Review body bytes affect the digest and remain in the private operational
snapshot store. They are not copied into emitted resource metadata. API URLs,
installation values, arbitrary links and unrelated webhook fields are ignored.

The emitted metadata reports whether the reviewed commit is still the current
pull-request head. An older exact commit is valid provider evidence and is
retained with `:github/review-current-head false`; it is not silently rewritten
to the latest head.

## Provider state is not an Ignatius decision

GitHub states are retained exactly:

```text
approved
changes_requested
commented
dismissed
```

They are not automatically translated to Ignatius's canonical review vocabulary:

```text
approve
reject
withdraw
```

A GitHub account is also not assumed to be an Ignatius reviewer key. The later
signing bridge must let the actual Ignatius signer inspect the exact review
snapshot, choose the canonical decision, sign it, and update only that signer's
reviewer-specific compare-and-set ref.

This distinction prevents a webhook, repository administrator or provider
account mapping from acquiring canonical review authority.

## Validation

The adapter rejects:

- unsupported actions or review states;
- a dismissed action whose state is not `dismissed`;
- submitted or edited events whose state is `dismissed`;
- submitted reviews with a predecessor;
- edited or dismissed reviews without a predecessor;
- submitted/edited actors that do not match the review author;
- malformed repository, pull-request, user, object-ID, timestamp and root
  values;
- inconsistent base repository or pull-request numbers; and
- an impossible open-and-merged pull-request state.

The review commit is width-checked against the pull-request object format but
is deliberately not required to equal the current head. This preserves stale
review evidence rather than destroying it.

## Replay and durability

With `--outbox-db`, exact payload identity, canonical snapshot bytes and the
single ordered resource event are committed atomically. Replaying the same
GitHub delivery returns the same event and adds no row. Reusing a delivery ID
with different bytes or event content is rejected.

Run the executable fixture with:

```sh
python3 scripts/test-ignatius-github-review
```

The fixture proves initial approval, body edit, administrator dismissal, review
of an older commit, exact predecessor chaining, private-body non-disclosure,
replay, durable row counts and rejection of contradictory or malformed input.
