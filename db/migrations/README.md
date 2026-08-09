# Ignatius chain migrations

`../sql/full.sql` is the generated fresh-install baseline and contains
destructive `DROP TABLE` statements. It is never an upgrade mechanism.

Existing nodes are upgraded by ordered SQL files in this directory. A migration
must be:

- non-destructive and safe to retry or guarded by the installed version;
- applied in one transaction while holding the Ignatius migration lock;
- recorded with its exact digest, schema version and protocol version;
- rejected when the installed version is newer or the client protocol range is
  incompatible; and
- verified by chain integrity checks before the node accepts submissions.

Migration names use `NNNN-description.sql`. The first migration will introduce
the version registry without renaming `gw_ledger`, changing canonical columns,
or regenerating historical values. Its implementation is intentionally kept
separate from the generated baseline and coordinated with the active
`gwdb.ledger.*` HAL port.
