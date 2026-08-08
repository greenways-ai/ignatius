# HCV1 flat-map measurement evidence

This directory contains measured evidence for the existing HCV1 root-map
implementation. It is the runtime counterpart to the exact structural model in
`docs/hpt1-workload-corpus.md`.

## What is measured

The runner builds canonical maps with fixed-width string keys and immutable
string-value roots at these default entry counts:

```text
16 · 64 · 256 · 1,024 · 4,096
```

For each map it records:

- fixture construction latency;
- stored payload bytes and key/value `CellRef` counts;
- first, middle and last successful lookup;
- missing lookup before and after the represented key range;
- replacement of first, middle and last values;
- append and interior insertion of a new key;
- the exact canonical map-cell and derived-reference writes for each mutation; and
- every raw timing sample plus median and p95.

The measurements use `System.nanoTime` around one generated PostgreSQL function
call. They therefore represent a warmed JDBC round trip through the same runtime
adapter used by the database tests, not isolated PostgreSQL executor CPU time.
That scope is recorded in the evidence rather than hidden. Write amplification is
reported from the canonical operation shape: replacement writes one map cell and
`2n` derived refs; insertion writes one map cell and `2(n+1)` derived refs. Key and
value cells are prepared before the timed call.

## Reproduction

From the repository root:

```sh
make hpt1-flat-map-benchmark
```

The target:

1. materializes the pinned Hara and Foundation revisions;
2. builds the repository's PostgreSQL 15 + pgsodium image;
3. creates a temporary ledger database through the standard Tahto JDBC runtime;
4. runs two warm-ups and seven measured samples by default; and
5. writes `benchmarks/hpt1-flat-map/evidence.edn`.

The scale and sample count can be overridden:

```sh
HPT1_BENCHMARK_COUNTS=16,64,256 \
HPT1_BENCHMARK_WARMUPS=3 \
HPT1_BENCHMARK_SAMPLES=11 \
make hpt1-flat-map-benchmark
```

## Interpretation boundary

Each entry-count case is isolated in the evidence: a practical recursion,
timeout or resource failure at a larger scale is recorded as an error result rather
than discarding successful smaller measurements.

This evidence establishes the cost curve of the current flat representation. It
does not prove a particular HPT1 format is better. A canonical HPT1 proposal must
still provide identical portable/PostgreSQL roots, deterministic node boundaries,
get/assoc/delete/iterate, structural diff, three-way merge and explicit HCV1
interoperability.

Runner source:
[`db/src/ledger/hpt1_flat_map_benchmark.clj`](../../db/src/ledger/hpt1_flat_map_benchmark.clj)
