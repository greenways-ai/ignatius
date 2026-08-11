# Agent Workflow operational status

`ignatius-agent-workflow-status` provides a read-only, value-sanitized health
view over the SQLite stores used by an Agent Workflow application. It is an
operator view over rebuildable host state. It does not read or change canonical
Ignatius work, receipts, checkpoints, resources, proposals, or releases.

## Run it

Bind each operational database to a short, non-sensitive role:

```sh
scripts/ignatius-agent workflow-status \
  ingress=var/github-ingress.sqlite \
  effects=var/github-effects.sqlite \
  workers=var/worker-execution.sqlite
```

The direct command is equivalent:

```sh
scripts/ignatius-agent-workflow-status \
  ingress=var/github-ingress.sqlite \
  effects=var/github-effects.sqlite
```

Roles must be unique and match `[a-z][a-z0-9_.-]{0,63}`. Each database is
identified in output only by its role and a SHA-256 digest of its normalized
absolute path. No filesystem path or database row value is printed.

Use `--strict` for health-check and service-manager integration:

```text
0  healthy
1  attention
2  blocked, invalid invocation, or unavailable command
```

`--now <RFC3339>` supplies a deterministic clock for fixtures and offline
inspection. Production calls normally omit it.

## Output contract

The command emits one compact canonical JSON object using protocol
`ignatius.agent-workflow-status/0-alpha`:

```json
{
  "databases": [
    {
      "file": {
        "mode": "0600",
        "private": true,
        "sidecars": {
          "not_regular": 0,
          "present": 1,
          "private": 1,
          "symlink": 0
        }
      },
      "health": "attention",
      "path_sha256": "sha256:...",
      "reasons": ["pending-work-present"],
      "role": "effects",
      "summary": {
        "due_attempts": 1,
        "expired_leases": 0,
        "in_flight": 0,
        "pending": 1,
        "successful": 4,
        "terminal_failure": 0,
        "unknown": 0
      },
      "tables": []
    }
  ],
  "generated_at": "2026-08-08T12:00:00Z",
  "health": "attention",
  "protocol": "ignatius.agent-workflow-status/0-alpha",
  "summary": {}
}
```

The example is abbreviated. The real `summary` repeats the bounded counters
across all databases and includes database health counts. Each recognized table
also reports state counts, due attempts, expired leases, and aggregate attempt
and fencing-generation statistics. It never reports identifiers, effect bytes,
receipts, event vectors, lease tokens, roots, diagnostics, or arbitrary state
strings.

## Recognized operational shape

A table is considered operational only when it has a `state` or `status`
column. Other tables, including immutable snapshot and delivery metadata tables,
are listed as ignored and are not queried for row content.

The following normalized states are allowlisted:

```text
pending
  available pending queued ready retry retryable scheduled waiting

in_flight
  claimed delivering executing in_flight leased processing running

successful
  accepted committed complete completed delivered done succeeded successful

terminal_failure
  canceled cancelled dead dead_letter exhausted failed rejected terminal_failure
```

Every other state contributes only to the `unknown` count. Its value is never
echoed. Unknown states and terminal failures make the database `blocked`.

The inspector recognizes common compatible column names for:

- attempts and retry counts;
- fencing or lease generations;
- lease expiry; and
- next-attempt or availability time.

Timestamps may be SQLite-readable text or numeric Unix time. A pending row with
no due-time column is conservatively counted as due. An in-flight row without a
lease column is not assumed expired.

## Health interpretation

`healthy` means every inspected database is readable and private, every
operational state is recognized, and no current or historical retry signal needs
attention.

`attention` means the schema is valid but work is pending or in flight, an
attempt is due, a lease has expired, or a nonzero attempt count shows retry
history. This is an operator signal, not a canonical workflow failure.

`blocked` means the view cannot safely establish operational health. Causes
include terminal or unknown states, negative counters, an unknown schema, an
unreadable or corrupt database, unsafe table names, non-private files, symlinks,
or replacement of the database during inspection.

## Read-only and disclosure boundary

The command:

- rejects symlinks in the supplied database path and in SQLite sidecar files;
- requires the database and present sidecars to be regular private files;
- opens SQLite with `mode=ro` and `query_only`;
- disables trusted schema execution and performs a bounded quick check;
- reads schema names and aggregate expressions only;
- quotes every accepted table and column identifier;
- hashes unsafe table names rather than returning them;
- verifies that the database inode did not change while it was open; and
- reduces all SQLite and filesystem failures to fixed diagnostics.

The status document is safe to send to an operator or monitoring system only to
the extent that roles, counts, modes, table names, and timing aggregates are
acceptable operational metadata. It is intentionally not a debug dump.

## Fixture

Run the complete executable fixture with:

```sh
scripts/test-ignatius-agent-workflow-status
```

It exercises the current GitHub ingress outbox shape, a fenced effect-delivery
shape, worker failures, unknown states, due retries, expired leases, private
mode checks, unsafe names, symlink rejection, strict exit codes, aggregate
routing, deterministic output, and proof that private row values and database
paths do not appear.
