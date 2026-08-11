---
title: Contracts and actors
description: Canonical Hara reducers, accounts, and governed lifecycle events.
---
# Contracts and actors

Contracts are immutable Hara state machines. Templates define the accepted event vocabulary, reducer, views, and canonical state. Accounts sign transactions that select a template and submit exact events.

Actor-style workflows preserve the same chain laws: explicit authority, deterministic reduction, optimistic expected-head checks, and receipt-bound results.
