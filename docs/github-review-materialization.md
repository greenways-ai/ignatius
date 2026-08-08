# Signer-visible GitHub review materialization

`ignatius-agent github-review-materialize` turns one exact immutable GitHub
review snapshot into a bounded document that an Ignatius reviewer can inspect
before constructing a canonical signed review decision.

It is deliberately a **read-only presentation boundary**:

```text
verified GitHub review webhook
  -> immutable github/pull-request-review-snapshot
  -> signer-visible materialization
  -> human or agent chooses an Ignatius decision
  -> existing workspace-review signing request
  -> reviewer signature
  -> existing signed review submission and reviewer-specific CAS
```

The command implements only the middle step. It does not choose a decision,
derive an Ignatius reviewer key from a GitHub account, build signing bytes,
submit a transaction, update a review ref, advance workspace `main`, or publish
a release.

## Materialize an exact snapshot

```sh
scripts/ignatius-agent github-review-materialize \
  --database var/ignatius-github.sqlite \
  --snapshot-version sha256:<exact-review-snapshot-digest> \
  --workspace greenways/ignatius \
  --repository greenways-ai/ignatius \
  --candidate-root <published-workspace-candidate-root> \
  --origin-root <expected-proposal-publisher-root>
```

The direct command is equivalent:

```sh
python3 scripts/ignatius-agent-github-review-materialize \
  --database var/ignatius-github.sqlite \
  ...
```

The caller must supply all four expected bindings. The command rejects a
snapshot whose workspace, repository, candidate root or proposal origin differs
from those values. This prevents a correct review of one proposal from being
presented as evidence for another.

## Output contract

The command emits one compact canonical JSON object using protocol:

```text
ignatius.github-review-materialization/1
```

Its major sections are:

- `source`: exact logical resource ID, snapshot version, SHA-256 digest and byte
  size;
- `proposal`: workspace, candidate, proposal origin and derived immutable
  proposal ref;
- `pull_request`: exact provider identities, state, refs and Git object IDs;
- `review`: exact author, action actor, provider state, reviewed commit,
  submitted time, author association and body evidence;
- `canonical_review`: the constrained handoff to Ignatius's existing signed
  review protocol; and
- `canonical_review_protocol`: limitations of the currently admitted canonical
  review record.

The canonical handoff is intentionally incomplete:

```json
{
  "policy": "review-decision-v1",
  "allowed_decisions": ["approve", "reject", "withdraw"],
  "selected_decision": null,
  "reviewer_root": null,
  "expected_review_root": null,
  "signing_required": true,
  "provider_state_authoritative": false
}
```

A GitHub state such as `approved` remains visible provider evidence. It does not
populate `selected_decision`. The actual Ignatius reviewer must choose the
canonical decision, use their signer-derived reviewer root, name the exact
current reviewer ref as the compare-and-set expectation, inspect the standard
signing payload, and sign through the already implemented workspace review
transaction.

## Current canonical evidence-binding limit

The current `review-decision-v1` validator requires:

```text
review/evidence-roots = []
review/process-run-id = nil
review/process-run-root = nil
review/metadata = {}
```

It rejects non-empty review evidence roots. Therefore this materialization names
and verifies the exact GitHub snapshot for signer inspection, but the existing
signed decision cannot yet contain a cryptographic reference back to that
provider snapshot.

The output makes this limitation explicit:

```json
{
  "canonical_review_protocol": {
    "evidence_roots": [],
    "provider_snapshot_binding": null,
    "provider_snapshot_binding_supported": false,
    "recorded_at": null,
    "process_run_id": null,
    "process_run_root": null
  }
}
```

This slice must not be described as a signed provider-evidence binding. A later
canonical protocol change must introduce one closed, validated evidence
reference before an admitted review can claim that property. Until then, the
source snapshot and the canonical review remain adjacent but distinct exact
objects.

## Review body handling

By default, the packet includes the exact UTF-8 review body because the document
is intended for the signer who must inspect the provider evidence. It also
includes whether the body is null or present, its UTF-8 byte length and SHA-256
digest.

Use `--redact-body` when routing the packet through a surface that should retain
body identity without displaying its text:

```sh
scripts/ignatius-agent github-review-materialize \
  ... \
  --redact-body
```

Redaction does not alter the source snapshot identity. The packet still names
the exact immutable snapshot and body digest; only the materialized `text` field
is null.

This output is signer material, not a monitoring document. The operational
status command remains the appropriate value-sanitized health surface.

## Exactness and stale reviews

The materializer recomputes the SHA-256 digest over the stored canonical JSON
and requires it to equal the requested `sha256:` version. It then requires the
stored bytes to be the canonical encoding accepted by the review adapter and
validates the closed snapshot shape again.

The exact review commit is retained even when it differs from the current pull
request head:

```text
review.commit_sha != pull_request.head.sha
  -> review.current_head = false
```

A stale review is therefore not rewritten, dropped or treated as current. The
signer and later policy layer can reject or supersede it explicitly.

## Read-only SQLite boundary

The command treats the GitHub ingress database as private operational state. It:

- rejects a supplied database or present SQLite sidecar that is a symlink;
- requires the database and present sidecars to be private regular files;
- opens SQLite using `mode=ro`;
- enables `query_only`, disables trusted schema execution and performs a bounded
  quick integrity check;
- verifies the `github_snapshot` schema before reading one exact row;
- enforces stored and actual snapshot byte sizes;
- caps snapshot and review-body sizes;
- rechecks the database inode and sidecars after closing the connection; and
- reduces filesystem, SQLite and malformed-value failures to bounded error
  codes without printing paths, payloads or arbitrary database values.

The command never changes delivery, snapshot or outbox state.

## Fixture

Run:

```sh
python3 scripts/test-ignatius-agent-github-review-materialize
```

The fixture uses the real review webhook adapter and SQLite snapshot store. It
proves exact direct and aggregate routing, deterministic replay, body inclusion
and redaction, stale-commit presentation, unchanged database bytes, binding
mismatch rejection, private-file and symlink enforcement, version/size/canonical
JSON checks, closed snapshot-shape validation and bounded oversized-body
rejection.

The fixture also asserts that no selected canonical decision, reviewer root or
expected review root is inferred from provider state. The emitted protocol-limit
object separately records that the current canonical review cannot bind the
provider snapshot as review evidence.
