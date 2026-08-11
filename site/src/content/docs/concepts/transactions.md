---
title: Transactions, blocks, and receipts
description: The signed admission and linear commitment law.
---
# Transactions, blocks, and receipts

A transaction binds its signer, account sequence, operation pack, expected state, and canonical payload. Admission verifies the signature and sequencing before deterministic execution.

The committed receipt binds the transaction root, result root, prior and resulting state roots, and block root. A local evaluator is useful for preparation and conformance, but only the PostgreSQL chain creates authoritative commitment.
