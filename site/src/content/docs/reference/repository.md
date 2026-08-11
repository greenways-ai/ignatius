---
title: Repository layout
description: Find the chain, portable client, adapters, extensions, docs, and conformance evidence.
---
# Repository layout

| Path | Responsibility |
| --- | --- |
| `db/` | Authoritative PostgreSQL chain and generated contracts |
| `hal/` | Portable client, evaluator, and workflow manager |
| `docs/` | Canonical architecture and workflow design |
| `scripts/` | Verification, generation, migrations, and provider adapters |
| `extensions/` | Bounded native capabilities such as SHA |
| `examples/` | Conformance and integration examples |

Vendored checkouts under ignored local directories are dependencies, not Ignatius documentation.
