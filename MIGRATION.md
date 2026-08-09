# Initial extraction

Ignatius was extracted with filtered Git history from
`greenways-ai/hestia` at `62a0cf9c658e9f81c91d3ef16b0f9b3380f0b33c`.

The filtered history tip is `4b3362a534e8849d5f55230fe8f0382a8c40248c`.

Included:

- the generic PostgreSQL Hara ledger;
- HCV1/HCP1 codec and runtime semantics;
- transaction and offline outbox HAL modules;
- generic chain contracts and tests; and
- SHA and Noir chain extensions.

Excluded and retained by Hestia:

- agent profiles, mandates and application authority;
- private rooms, invitations and negotiation;
- document OT, provenance, approval and delivery;
- continuity and recovery ceremonies; and
- Hestia services and product experiences.

## Remaining extraction stages

The source extraction is not the release boundary. The following stages remain
explicitly unfinished:

1. publish an Ignatius release containing the stable `postgres.core` chain
   surface and schema/protocol compatibility contract;
2. replace Hestia's copied ledger dependency with that pinned release;
3. upgrade the existing `gw_ledger` schema in place and adopt existing Hestia
   heads through signed migration transactions without re-encoding history;
4. dual-run legacy and generic submission until roots and outcomes agree;
5. rebuild retained Hestia projections from canonical records and receipts;
6. remove compatibility copies only after backup, replay, rollback and
   integrity verification pass.

The active chain work is tracked by
[Ignatius #76](https://github.com/greenways-ai/ignatius/issues/76) and the
application migration by
[Hestia #28](https://github.com/greenways-ai/hestia/issues/28).
