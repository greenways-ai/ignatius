# HPT0 workload corpus and flat-map baseline

HPT0 is a proposed large persistent index format. It is not yet a canonical
codec, type tag or migration target. This slice first fixes the workloads and the
current HCV0 structural baseline so later design choices are supported by
repeatable evidence rather than an assumed Prolly-tree benefit.

## Current HCV0 map cost

An HCV0 map payload is:

```text
M:<entry-count>:<key-root><value-root>...
```

Each SHA-256 root is transported as sixty-four lowercase ASCII hex characters.
For `n` entries, the exact payload size is therefore:

```text
3 + decimal_digits(n) + 128n bytes
```

The outer `HCV0:<type>:<length>:` envelope is excluded because the comparison in
this corpus concerns the immutable map payload and its child graph. Every map
entry also derives two `CellRef` rows: one `key` edge and one `value` edge.

The current PostgreSQL map implementation scans keys in canonical order. In the
worst case, lookup performs `n` canonical-byte comparisons. Associating either an
existing or a new key rebuilds the complete map payload and all derived refs.

| Entries | Payload bytes | Derived refs | Worst-case get comparisons |
| ---: | ---: | ---: | ---: |
| 16 | 2,053 | 32 | 16 |
| 64 | 8,197 | 128 | 64 |
| 256 | 32,774 | 512 | 256 |
| 1,024 | 131,079 | 2,048 | 1,024 |
| 4,096 | 524,295 | 8,192 | 4,096 |
| 16,384 | 2,097,160 | 32,768 | 16,384 |
| 65,536 | 8,388,616 | 131,072 | 65,536 |

These figures are exact structural costs, not elapsed-time measurements.

## Evidence bands

The portable workload contract classifies entry counts into provisional bands:

```text
0–64       :hcv1/preferred
65–255     :benchmark/required
256+       :hpt1/candidate
```

These are experiment-selection bands. They do not automatically change a codec
or prove that HPT0 is faster. A flat HCV0 map may remain the right representation
for semantic records even above a provisional boundary, while a high-churn index
may justify chunking earlier.

## Initial workload corpus

### Scene entity index

Maps stable entity IDs to exact entity roots. The corpus uses 1,024, 16,384 and
65,536 entries with random point reads and sparse component batches. This models
large world and scene registries without making component datoms canonical.

### DOM and document node index

Maps stable node IDs to exact node roots at 256, 4,096 and 16,384 entries. Reads
mix point lookup and subtree traversal; writes are localized edit batches. Ordered
child lists remain separate explicit values rather than being hidden inside the
index policy.

### Hara namespace bindings

Maps qualified symbols to immutable definition roots at 64, 256 and 4,096
entries. Reads model dependency-closure hydration and writes model sparse binding
updates. This workload is intentionally linked to issue #15 but does not define
the namespace-commit format.

### Process catalog

Maps stable process IDs to exact process-definition roots at 256, 4,096 and
65,536 entries. Reads are mostly point lookups; writes append definitions and
revise selected bindings.

## Required operation scenarios

Every candidate HPT0 design must report at least:

- get at the first, middle and last key;
- missing get before and after the represented key range;
- replacement of first, middle and last existing keys;
- append and interior insertion of a new key;
- full deterministic iteration;
- same-root, one-change and one-percent structural diff;
- disjoint three-way merge and same-key conflict.

Diff and merge are product requirements. They cannot be inferred from a storage
library or omitted from the first canonical-format proposal.

## Evidence format for the next slice

Runtime measurements must commit enough information to reproduce the result:

- Ignatius commit and generated SQL root;
- pinned Hara and Foundation revisions;
- PostgreSQL image and configuration;
- workload ID, entry count and deterministic seed;
- warm-up count and raw measured samples;
- median and p95 latency;
- payload bytes, derived refs and newly written cells;
- roots visited by get, diff and merge where observable.

The next slice should add a PostgreSQL benchmark runner for the existing flat-map
implementation and commit the raw evidence. Only after those results should the
project freeze HPT0 node framing, chunk-boundary rules, hash domain, child roles
or interoperability rules.

## Compatibility boundary

HPT0 must be additive:

- existing HCV0 and HCP0 roots remain unchanged;
- ordinary HCV0 maps remain canonical for small semantic values;
- a future HPT0 root receives an explicit versioned format and test vectors;
- PostgreSQL and portable runtimes must construct identical roots;
- conversion between HCV0 maps and HPT0 indexes is explicit and never rewrites
  historical values in place.

The executable baseline is maintained in
[`hal/src/ignatius/hpt1_workload.hal`](../hal/src/ignatius/hpt1_workload.hal)
and its portable assertions in
[`hal/test/ignatius/hpt1_workload_test.hal`](../hal/test/ignatius/hpt1_workload_test.hal).
