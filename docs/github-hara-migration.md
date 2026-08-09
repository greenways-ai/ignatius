# GitHub adapter migration from Python to Hara

Ignatius canonical planning belongs in `.hal`. Provider transports may verify
HTTP signatures, read Git objects and supply capability results, but they must
not independently construct Ignatius workflow events.

## Release train

```text
verified provider bytes
  -> normalized provider facts
  -> ignatius.github-workflow/event-plan
  -> exact Ignatius event vector
  -> signed admission
  -> PostgreSQL ledger
```

The migration is staged so the existing Python adapters remain executable
compatibility oracles until the Hara planners are proven equivalent and callers
switch over.

## Compatibility vectors

`hal/src/ignatius/github/compatibility_vectors.hal` freezes complete event
vectors produced by the current Python planners. It is packaged Hara source so
both the planner-parity suite and the `std.work` delivery suite consume exactly
the same compatibility facts.

| Vector | Python source | Snapshot digest |
|---|---|---|
| `:python/issue-open-v1` | `ignatius_github_issue.py::_issue_events` | SHA-256 over 438 canonical JSON bytes |
| `:python/push-update-v1` | `ignatius_github_push.py::push_events` | SHA-256 over 484 canonical JSON bytes |

The vectors include:

- normalized provider facts;
- exact canonical snapshot byte counts and digests;
- every emitted event field;
- complete metadata maps;
- exact logical references;
- Git ancestry and Ignatius compare-and-set predecessors.

`ignatius.github-compatibility-test` passes each fact envelope through the
public Hara dispatcher and compares the whole result with the frozen Python
output. A selected-field comparison is insufficient because it could hide a
change to authority, ancestry, evidence or exact resource identity.

## Hash and JSON boundary

The current transport supplies three explicit values:

```clojure
{:snapshot normalized-provider-facts
 :snapshot/digest lowercase-sha256
 :snapshot/size canonical-json-byte-count}
```

Hara validates their bounded shape, derives `sha256:<digest>` resource
versions and owns all event construction. This avoids the earlier invalid
`record/sha256-canonical` placeholder.

A later capability slice will move canonical JSON byte production and SHA-256
invocation behind Hara host capabilities. Until then, the committed digest and
byte-count vectors prevent either implementation from changing silently.

## Retirement rule

A Python planner may be removed only after:

1. its provider actions have complete Hara planners;
2. complete compatibility vectors pass through the public Hara dispatcher;
3. the production caller invokes Hara rather than Python for event planning;
4. exact signed admission and replay fixtures remain green; and
5. Python no longer constructs canonical Ignatius event maps.

SQLite retention is a separate operational concern. It is moved behind the
`std.work` store provider boundary in the next PR; PostgreSQL remains the
production durable adapter and canonical ledger.
