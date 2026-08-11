---
title: Introduction
description: Understand the Ignatius chain, client, and application boundary.
---
# Introduction

Ignatius is the authoritative PostgreSQL chain for Greenways. It stores canonical HCV0/HCP0 state, orders signed transactions, executes deterministic Hara reducers, commits linear blocks, and returns exact receipts.

## Three boundaries

- `db/` implements the authoritative chain and retains its stable `gwdb.ledger.*` SQL names.
- `hal/` provides the portable client, local evaluator, and generic workflow manager.
- Applications own profiles, documents, mandates, approvals, projections, and interface policy.

Database handles and credentials remain inside the `postgres.core` capability. Portable HAL receives explicit request and result values.
