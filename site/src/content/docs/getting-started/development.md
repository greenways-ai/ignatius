---
title: Development workflow
description: Work across the HAL client, PostgreSQL chain, generated artefacts, and conformance checks.
---
# Development workflow

Run `make verify` for the complete repository boundary. It checks architecture, migrations, release compatibility, HAL parity, generated SQL and contracts, portable client tests, and the SHA extension.

Develop Hara and Foundation PostgreSQL forms through the repository's REPL-first workflow. Regenerate owned artefacts from their source forms and require a clean generated diff before delivery.
