# GitHub delivery over `std.work`

The GitHub adapter has two distinct durability responsibilities:

```text
canonical Ignatius truth
  signed transactions, workflow state, receipts and accepted heads
  -> PostgreSQL Ignatius adapter

operational host delivery
  provider inbox identity, retries, claims and pending submissions
  -> std.work store provider
```

SQLite is not a canonical Ignatius database. During the migration it remains a
compatibility implementation for the existing Python adapter only. New Hara
workflow code targets the `std.work` store contract rather than SQLite tables.

## Hara boundary

`ignatius.github.delivery/enqueue-plan!` accepts:

```clojure
store-provider
provider-delivery-id
exact-plan-root
ordered-Ignatius-events
```

It creates one deterministic work run and commits, in one store transition:

- the queued delivery state;
- one bounded operational event; and
- one ordered outbox intent for each planned Ignatius transaction.

The outbox keys are:

```clojure
["ignatius.github.delivery/1" delivery-id position]
```

Replaying the same delivery ID, plan root and event vector returns the existing
run and outbox. Reusing the delivery ID with a different plan or event vector is
an identity conflict.

## Store contract

The implementation consumes the standard `std.work.runtime.store` provider
operations:

```text
create-run
load-run
transact
list-outbox
claim-outbox
ack-outbox
```

It does not import SQLite or PostgreSQL APIs. The in-memory provider is used by
the portable fixture solely to prove the contract.

## Production mapping

The production provider remains PostgreSQL-first:

```text
std.work run
  -> provider delivery identity and exact plan root

std.work transition
  -> queued state + event + ordered outbox rows

outbox claimant
  -> capability-bound signer
  -> Ignatius PostgreSQL admission

outbox acknowledgement
  -> accepted canonical transaction receipt
```

The PostgreSQL provider must make the run transition and ordered outbox insert
atomic. It may maintain retry, lease and dead-letter columns as rebuildable
operational state, but those columns are not substitutes for canonical
Ignatius receipts.

## Hara pin

Ignatius previously pinned Hara `99a0b106…`, before the current `std.work`
provider and receipt-outbox contracts existed. This slice advances the pin to:

```text
d305875e3bfe3d8fc4f8a1462053e4ca901aaa74
```

That revision includes the provider-role store contract and
`hara.work.receipt/1` outbox boundary. The full Ignatius Verify workflow remains
the gate for generated SQL, generated contracts and portable HAL behavior.

## Remaining migration

This PR establishes the storage-neutral Hara boundary. Follow-up work under
#65 will:

1. implement the PostgreSQL `std.work` store provider;
2. route the GitHub webhook host through `enqueue-plan!`;
3. retain SQLite only as an explicitly selected embedded provider;
4. remove Python-owned outbox and status semantics; and
5. prove restart, claim, acknowledgement and replay against PostgreSQL.
