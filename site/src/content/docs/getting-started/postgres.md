---
title: PostgreSQL chain
description: Generate, migrate, and verify the authoritative database implementation.
---
# PostgreSQL chain

Ignatius treats PostgreSQL as the reference node rather than placing an ambient HTTP service in front of it.

## Generated artefacts

Foundation PostgreSQL DSL sources own the generated SQL and client contracts. Never edit generated `gwdb.rpc` or SQL artefacts directly.

Use the repository Makefile to set up exact dependencies and run the verification boundary. Database migrations are forward-only release artefacts and are tested against the supported PostgreSQL profile.

See the [database source guide ↗](https://github.com/greenways-ai/ignatius/tree/main/db) for exact local commands and prerequisites.
