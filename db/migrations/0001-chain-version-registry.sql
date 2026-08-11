CREATE TABLE IF NOT EXISTS "gw_ledger"."ChainMigration" (
  "version" BIGINT PRIMARY KEY CHECK ("version" > 0),
  "name" TEXT NOT NULL UNIQUE,
  "digest" BYTEA NOT NULL CHECK (octet_length("digest") = 32),
  "schema_version" BIGINT NOT NULL CHECK ("schema_version" > 0),
  "protocol_version" TEXT NOT NULL CHECK (length("protocol_version") > 0),
  "applied_at" TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

COMMENT ON TABLE "gw_ledger"."ChainMigration" IS
  'Ordered, digest-bound additive upgrades applied to this Ignatius chain.';

REVOKE UPDATE, DELETE, TRUNCATE ON "gw_ledger"."ChainMigration" FROM PUBLIC;
