

CREATE SCHEMA IF NOT EXISTS "gw_ledger";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE SCHEMA IF NOT EXISTS "gw_ledger";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- gwdb.ledger.codec/sha256 [15] 
CREATE OR REPLACE FUNCTION "gw_ledger".sha256(
  input BYTEA
) RETURNS BYTEA AS $$

  SELECT public.digest(input,'sha256');

$$ LANGUAGE 'sql' IMMUTABLE PARALLEL SAFE;

-- gwdb.ledger.codec/hash-valid [24] 
CREATE OR REPLACE FUNCTION "gw_ledger".hash_valid(
  input BYTEA
) RETURNS BOOLEAN AS $$

  SELECT length(input) = 32;

$$ LANGUAGE 'sql' IMMUTABLE PARALLEL SAFE;

-- gwdb.ledger.codec/canonical-encode [33] 
CREATE OR REPLACE FUNCTION "gw_ledger".canonical_encode(
  type_tag INTEGER,
  payload BYTEA
) RETURNS BYTEA AS $$

  SELECT decode(
    'HCV1:' || type_tag || ':' || length(payload) || ':' || encode(payload,'hex'),
    'escape'
  );

$$ LANGUAGE 'sql' IMMUTABLE PARALLEL SAFE;

-- gwdb.ledger.codec/canonical-hash [44] 
CREATE OR REPLACE FUNCTION "gw_ledger".canonical_hash(
  type_tag INTEGER,
  payload BYTEA
) RETURNS BYTEA AS $$

  SELECT public.digest("gw_ledger".canonical_encode(type_tag,payload),'sha256');

$$ LANGUAGE 'sql' IMMUTABLE PARALLEL SAFE;

-- gwdb.ledger.codec/valid-type-tag [54] 
CREATE OR REPLACE FUNCTION "gw_ledger".valid_type_tag(
  type_tag INTEGER
) RETURNS BOOLEAN AS $$

  SELECT (type_tag >= 0) AND (type_tag <= 20);

$$ LANGUAGE 'sql' IMMUTABLE PARALLEL SAFE;

-- gwdb.ledger.codec/framed-roots-valid [64] 
CREATE OR REPLACE FUNCTION "gw_ledger".framed_roots_valid(
  i_payload BYTEA,
  i_kind TEXT,
  i_roots_per_count INTEGER
) RETURNS BOOLEAN AS $$

  DECLARE
    v_count_text TEXT;
    v_roots TEXT;
    v_text TEXT;
  BEGIN
    v_text := encode(i_payload,'escape');
    v_count_text := split_part(v_text,':',2);
    v_roots := split_part(v_text,':',3);
    RETURN CASE WHEN regexp_match(v_text,'^' || i_kind || ':(0|[1-9][0-9]*):[0-9a-f]*$') IS NOT NULL THEN length(v_roots) = ((v_count_text)::BIGINT * 64 * i_roots_per_count)
    ELSE false
    END;
  END;

$$ LANGUAGE 'plpgsql' IMMUTABLE PARALLEL SAFE;

-- gwdb.ledger.codec/payload-valid [82] 
CREATE OR REPLACE FUNCTION "gw_ledger".payload_valid(
  i_type_tag INTEGER,
  i_payload BYTEA
) RETURNS BOOLEAN AS $$

  SELECT CASE WHEN i_type_tag = 0 THEN length(i_payload) = 0
  WHEN i_type_tag = 1 THEN (i_payload = decode('00','hex')) OR (i_payload = decode('01','hex'))
  WHEN i_type_tag = 2 THEN regexp_match(encode(i_payload,'escape'),'^-?(0|[1-9][0-9]*)$') IS NOT NULL
  WHEN i_type_tag = 3 THEN length(i_payload) = 8
  WHEN (i_type_tag = 9) OR (i_type_tag = 10) THEN "gw_ledger".framed_roots_valid(i_payload,'S',1)
  WHEN i_type_tag = 11 THEN "gw_ledger".framed_roots_valid(i_payload,'M',2)
  WHEN i_type_tag = 12 THEN "gw_ledger".framed_roots_valid(i_payload,'T',1)
  WHEN i_type_tag = 13 THEN "gw_ledger".framed_roots_valid(i_payload,'S',1) AND ((split_part(encode(i_payload,'escape'),':',2))::BIGINT = 2)
  ELSE true
  END;

$$ LANGUAGE 'sql' IMMUTABLE PARALLEL SAFE;

-- gwdb.ledger.codec/verify [112] 
CREATE OR REPLACE FUNCTION "gw_ledger".verify(
  i_hash BYTEA,
  i_type_tag INTEGER,
  i_payload BYTEA
) RETURNS BOOLEAN AS $$

  SELECT "gw_ledger".hash_valid(i_hash) AND "gw_ledger".valid_type_tag(i_type_tag) AND "gw_ledger".payload_valid(i_type_tag,i_payload) AND (i_hash = "gw_ledger".canonical_hash(i_type_tag,i_payload));

$$ LANGUAGE 'sql' IMMUTABLE PARALLEL SAFE;

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- gwdb.ledger.cell/Cell [16] 
DROP TABLE IF EXISTS "gw_ledger"."Cell" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."Cell" (
  "hash" BYTEA PRIMARY KEY,
  "codec_version" SMALLINT NOT NULL,
  "type_tag" SMALLINT NOT NULL,
  "payload" BYTEA NOT NULL,
  "byte_size" INTEGER NOT NULL,
  "created_at" BIGINT NOT NULL DEFAULT (1000000 * extract(epoch FROM now()))::BIGINT
);

-- gwdb.ledger.cell/CellRef [27] 
DROP TABLE IF EXISTS "gw_ledger"."CellRef" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."CellRef" (
  "parent_hash" BYTEA NOT NULL,
  "position" INTEGER NOT NULL,
  "role" TEXT NOT NULL,
  "child_hash" BYTEA NOT NULL,
  PRIMARY KEY (parent_hash,position,role)
);

-- gwdb.ledger.cell/cell-immutable [36] 
CREATE OR REPLACE FUNCTION "gw_ledger".cell_immutable() RETURNS TRIGGER AS $$
BEGIN
  IF NOT (false) THEN
    RAISE EXCEPTION USING
      DETAIL = (jsonb_build_object('status','error','tag','ledger/immutable_cell','data',null))::TEXT,
      MESSAGE = 'ledger/immutable-cell'
    ;
  END IF;
  RETURN OLD;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.cell/cell-immutable-update-trigger [44] 
DROP TRIGGER IF EXISTS cell_immutable_update_trigger ON "gw_ledger"."Cell";
CREATE TRIGGER cell_immutable_update_trigger BEFORE UPDATE ON "gw_ledger"."Cell"
FOR EACH ROW EXECUTE FUNCTION "gw_ledger".cell_immutable();

-- gwdb.ledger.cell/cell-immutable-delete-trigger [50] 
DROP TRIGGER IF EXISTS cell_immutable_delete_trigger ON "gw_ledger"."Cell";
CREATE TRIGGER cell_immutable_delete_trigger BEFORE DELETE ON "gw_ledger"."Cell"
FOR EACH ROW EXECUTE FUNCTION "gw_ledger".cell_immutable();

-- gwdb.ledger.cell/cell-hash-valid [56] 
CREATE OR REPLACE FUNCTION "gw_ledger".cell_hash_valid(
  i_hash BYTEA
) RETURNS BOOLEAN AS $$

  SELECT "gw_ledger".hash_valid(i_hash);

$$ LANGUAGE 'sql' IMMUTABLE PARALLEL SAFE;

-- gwdb.ledger.cell/cell-valid [65] 
CREATE OR REPLACE FUNCTION "gw_ledger".cell_valid(
  i_hash BYTEA,
  i_codec_version INTEGER,
  i_type_tag INTEGER,
  i_payload BYTEA
) RETURNS BOOLEAN AS $$

  SELECT (i_codec_version = 1) AND "gw_ledger".verify(i_hash,i_type_tag,i_payload);

$$ LANGUAGE 'sql' IMMUTABLE PARALLEL SAFE;

-- gwdb.ledger.cell/cell-by-hash [78] 
CREATE OR REPLACE FUNCTION "gw_ledger".cell_by_hash(
  i_hash BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_cell JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT
        "hash",
        "codec_version",
        "type_tag",
        "payload",
        "byte_size",
        "created_at"
      FROM "gw_ledger"."Cell"
      WHERE "hash" = i_hash
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_cell;
    RETURN o_cell;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.cell/cell-type-tag [86] 
CREATE OR REPLACE FUNCTION "gw_ledger".cell_type_tag(
  i_hash BYTEA
) RETURNS INTEGER AS $$

  DECLARE
    o_cell JSONB;
    v_type_tag INTEGER;
  BEGIN
    o_cell := "gw_ledger".cell_by_hash(i_hash);
    IF NOT (o_cell IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_cell','data',null))::TEXT,
        MESSAGE = 'ledger/missing-cell'
      ;
    END IF;
    v_type_tag := (o_cell ->> 'type_tag');
    RETURN v_type_tag;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.cell/cell-ref-count [97] 
CREATE OR REPLACE FUNCTION "gw_ledger".cell_ref_count(
  i_parent_hash BYTEA,
  i_role TEXT
) RETURNS INTEGER AS $$

  DECLARE
    o_count INTEGER;
  BEGIN
    SELECT count(*) FROM "gw_ledger"."CellRef"
    WHERE "parent_hash" = i_parent_hash AND "role" = i_role INTO o_count;
    RETURN o_count;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.cell/cell-ref-child [107] 
CREATE OR REPLACE FUNCTION "gw_ledger".cell_ref_child(
  i_parent_hash BYTEA,
  i_position INTEGER,
  i_role TEXT
) RETURNS BYTEA AS $$

  DECLARE
    o_row JSONB;
    v_child BYTEA;
  BEGIN
    WITH j_ret AS (  
      SELECT "parent_hash","position","role","child_hash" FROM "gw_ledger"."CellRef"
      WHERE "parent_hash" = i_parent_hash
      AND "position" = i_position
      AND "role" = i_role
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    IF NOT (o_row IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_cell_reference',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-cell-reference'
      ;
    END IF;
    v_child := (o_row ->> 'child_hash');
    RETURN v_child;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.cell/cell-ref-children [121] 
CREATE OR REPLACE FUNCTION "gw_ledger".cell_ref_children(
  i_parent_hash BYTEA
) RETURNS JSONB AS $$

  DECLARE
    v_rows JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT "child_hash" FROM "gw_ledger"."CellRef"
      WHERE "parent_hash" = i_parent_hash
      ORDER BY "role","position")
    SELECT jsonb_agg(j_ret) FROM j_ret INTO v_rows;
    RETURN coalesce(v_rows,jsonb_build_array());
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.cell/cell-ref-entries [133] 
CREATE OR REPLACE FUNCTION "gw_ledger".cell_ref_entries(
  i_parent_hash BYTEA
) RETURNS JSONB AS $$

  DECLARE
    v_rows JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT "position","role","child_hash" FROM "gw_ledger"."CellRef"
      WHERE "parent_hash" = i_parent_hash
      ORDER BY "role","position")
    SELECT jsonb_agg(j_ret) FROM j_ret INTO v_rows;
    RETURN coalesce(v_rows,jsonb_build_array());
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.cell/cell-put [145] 
CREATE OR REPLACE FUNCTION "gw_ledger".cell_put(
  i_hash BYTEA,
  i_codec_version INTEGER,
  i_type_tag INTEGER,
  i_payload BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_existing JSONB;
    o_insert JSONB;
    v_size INTEGER;
  BEGIN
    v_size := length(i_payload);
    o_existing := "gw_ledger".cell_by_hash(i_hash);
    o_insert := null;
    IF NOT (i_codec_version = 1) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/unsupported_codec',
          'data',
          i_codec_version
        ))::TEXT,
        MESSAGE = 'ledger/unsupported-codec'
      ;
    END IF;
    IF NOT ("gw_ledger".valid_type_tag(i_type_tag)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/unknown_type_tag',
          'data',
          i_type_tag
        ))::TEXT,
        MESSAGE = 'ledger/unknown-type-tag'
      ;
    END IF;
    IF NOT (length(i_hash) = 32) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_hash_length','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-hash-length'
      ;
    END IF;
    IF NOT ("gw_ledger".cell_valid(i_hash,i_codec_version,i_type_tag,i_payload)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/hash_mismatch','data',null))::TEXT,
        MESSAGE = 'ledger/hash-mismatch'
      ;
    END IF;
    IF o_existing is not null  THEN
      IF NOT   ((o_existing ->> 'codec_version')::SMALLINT = i_codec_version) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object('status','error','tag','ledger/cell_codec_conflict','data',null))::TEXT,
          MESSAGE = 'ledger/cell-codec-conflict'
        ;
      END IF;
      IF NOT ((o_existing ->> 'type_tag')::SMALLINT = i_type_tag) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object('status','error','tag','ledger/cell_type_conflict','data',null))::TEXT,
          MESSAGE = 'ledger/cell-type-conflict'
        ;
      END IF;
      IF NOT ((o_existing ->> 'payload')::BYTEA = i_payload) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object(
              'status',
              'error',
              'tag',
              'ledger/cell_payload_conflict',
              'data',
              null
            ))::TEXT,
          MESSAGE = 'ledger/cell-payload-conflict'
        ;
      END IF;
      RETURN i_hash;
    ELSE
      WITH j_ret AS (    
        INSERT INTO "gw_ledger"."Cell" ("hash","codec_version","type_tag","payload","byte_size") VALUES (
          (i_hash)::BYTEA,
          (i_codec_version)::SMALLINT,
          (i_type_tag)::SMALLINT,
          (i_payload)::BYTEA,
          (v_size)::INTEGER
        ) RETURNING
          "hash",
          "codec_version",
          "type_tag",
          "payload",
          "byte_size",
          "created_at")
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_insert;
      RETURN i_hash;
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.cell/cell-ref-put [184] 
CREATE OR REPLACE FUNCTION "gw_ledger".cell_ref_put(
  i_parent_hash BYTEA,
  i_position INTEGER,
  i_role TEXT,
  i_child_hash BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    IF NOT ("gw_ledger".cell_hash_valid(i_parent_hash)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_parent_hash','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-parent-hash'
      ;
    END IF;
    IF NOT ("gw_ledger".cell_hash_valid(i_child_hash)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_child_hash','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-child-hash'
      ;
    END IF;
    IF NOT (i_position >= 0) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_reference_position',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-reference-position'
      ;
    END IF;
    IF NOT ("gw_ledger".cell_by_hash(i_parent_hash) IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_parent_cell','data',null))::TEXT,
        MESSAGE = 'ledger/missing-parent-cell'
      ;
    END IF;
    IF NOT ("gw_ledger".cell_by_hash(i_child_hash) IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_child_cell','data',null))::TEXT,
        MESSAGE = 'ledger/missing-child-cell'
      ;
    END IF;
    WITH j_ret AS (  
      INSERT INTO "gw_ledger"."CellRef" ("parent_hash","position","role","child_hash") VALUES (
        (i_parent_hash)::BYTEA,
        (i_position)::INTEGER,
        (i_role)::TEXT,
        (i_child_hash)::BYTEA
      ) ON CONFLICT ("parent_hash","position","role") DO UPDATE SET ("parent_hash","position","role","child_hash") = row(
        EXCLUDED."parent_hash",
        EXCLUDED."position",
        EXCLUDED."role",
        EXCLUDED."child_hash"
      ) RETURNING "parent_hash","position","role","child_hash")
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.cell/cell-ref-valid [209] 
CREATE OR REPLACE FUNCTION "gw_ledger".cell_ref_valid(
  i_parent_hash BYTEA,
  i_child_hash BYTEA
) RETURNS BOOLEAN AS $$
BEGIN
  RETURN "gw_ledger".cell_by_hash(i_parent_hash) IS NOT NULL AND "gw_ledger".cell_by_hash(i_child_hash) IS NOT NULL;
END;
$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- gwdb.ledger.codec-value/encode [19] 
CREATE OR REPLACE FUNCTION "gw_ledger".encode(
  i_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_cell JSONB;
  BEGIN
    o_cell := "gw_ledger".cell_by_hash(i_root);
    IF NOT (o_cell IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_codec_cell','data',null))::TEXT,
        MESSAGE = 'ledger/missing-codec-cell'
      ;
    END IF;
    RETURN "gw_ledger".canonical_encode(
      (o_cell ->> 'type_tag')::INTEGER,
      (o_cell ->> 'payload')::BYTEA
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.codec-value/compare [30] 
CREATE OR REPLACE FUNCTION "gw_ledger".compare(
  i_left_root BYTEA,
  i_right_root BYTEA
) RETURNS INTEGER AS $$

  DECLARE
    v_left BYTEA;
    v_right BYTEA;
  BEGIN
    v_left := "gw_ledger".encode(i_left_root);
    v_right := "gw_ledger".encode(i_right_root);
    RETURN CASE WHEN v_left < v_right THEN -1
    WHEN v_left > v_right THEN 1
    ELSE 0
    END;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.codec-value/root-hex-valid [41] 
CREATE OR REPLACE FUNCTION "gw_ledger".root_hex_valid(
  i_root_hex TEXT
) RETURNS BOOLEAN AS $$

  SELECT (length(i_root_hex) = 64) AND regexp_match(i_root_hex,'^[0-9a-f]{64}$') IS NOT NULL;

$$ LANGUAGE 'sql' IMMUTABLE PARALLEL SAFE;

-- gwdb.ledger.codec-value/child-root-at [51] 
CREATE OR REPLACE FUNCTION "gw_ledger".child_root_at(
  i_child_roots JSONB,
  i_position INTEGER
) RETURNS BYTEA AS $$

  DECLARE
    o_child JSONB;
    v_child_hex TEXT;
    v_child_root BYTEA;
  BEGIN
    v_child_hex := (i_child_roots ->> i_position);
    IF NOT ("gw_ledger".root_hex_valid(v_child_hex)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_child_root','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-child-root'
      ;
    END IF;
    v_child_root := decode(v_child_hex,'hex');
    o_child := "gw_ledger".cell_by_hash(v_child_root);
    IF NOT (o_child IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_child_cell','data',null))::TEXT,
        MESSAGE = 'ledger/missing-child-cell'
      ;
    END IF;
    RETURN v_child_root;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.codec-value/sequence-payload-tail [64] 
CREATE OR REPLACE FUNCTION "gw_ledger".sequence_payload_tail(
  i_child_roots JSONB,
  i_position INTEGER,
  i_count INTEGER
) RETURNS TEXT AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN '';
  ELSE
    DECLARE
    v_child_hex TEXT;
      v_child_root BYTEA;
      v_tail TEXT;
  BEGIN
    v_child_root := "gw_ledger".child_root_at(i_child_roots,i_position);
      v_child_hex := encode(v_child_root,'hex');
      v_tail := "gw_ledger".sequence_payload_tail(i_child_roots,i_position + 1,i_count);
      RETURN v_child_hex || v_tail;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.codec-value/sequence-payload [77] 
CREATE OR REPLACE FUNCTION "gw_ledger".sequence_payload(
  i_child_roots JSONB
) RETURNS BYTEA AS $$

  DECLARE
    v_count INTEGER;
    v_prefix TEXT;
    v_tail TEXT;
  BEGIN
    v_count := jsonb_array_length(i_child_roots);
    IF NOT (v_count IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/children_must_be_array',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/children-must-be-array'
      ;
    END IF;
    v_prefix := ('S:' || v_count || ':');
    v_tail := "gw_ledger".sequence_payload_tail(i_child_roots,0,v_count);
    RETURN decode(v_prefix || v_tail,'escape');
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.codec-value/roots-strictly-ordered [91] 
CREATE OR REPLACE FUNCTION "gw_ledger".roots_strictly_ordered(
  i_child_roots JSONB,
  i_position INTEGER,
  i_count INTEGER
) RETURNS BOOLEAN AS $$
BEGIN
  IF (i_position + 1) >= i_count THEN
    RETURN true;
  ELSE
    DECLARE
    v_left BYTEA;
      v_right BYTEA;
  BEGIN
    v_left := "gw_ledger".child_root_at(i_child_roots,i_position);
      v_right := "gw_ledger".child_root_at(i_child_roots,i_position + 1);
      RETURN ("gw_ledger".compare(v_left,v_right) < 0) AND "gw_ledger".roots_strictly_ordered(i_child_roots,i_position + 1,i_count);
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.codec-value/map-keys-strictly-ordered [104] 
CREATE OR REPLACE FUNCTION "gw_ledger".map_keys_strictly_ordered(
  i_child_roots JSONB,
  i_position INTEGER,
  i_count INTEGER
) RETURNS BOOLEAN AS $$
BEGIN
  IF (i_position + 2) >= i_count THEN
    RETURN true;
  ELSE
    DECLARE
    v_left BYTEA;
      v_right BYTEA;
  BEGIN
    v_left := "gw_ledger".child_root_at(i_child_roots,i_position);
      v_right := "gw_ledger".child_root_at(i_child_roots,i_position + 2);
      RETURN ("gw_ledger".compare(v_left,v_right) < 0) AND "gw_ledger".map_keys_strictly_ordered(i_child_roots,i_position + 2,i_count);
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.codec-value/set-payload [117] 
CREATE OR REPLACE FUNCTION "gw_ledger".set_payload(
  i_child_roots JSONB
) RETURNS BYTEA AS $$

  DECLARE
    v_count INTEGER;
    v_prefix TEXT;
    v_tail TEXT;
  BEGIN
    v_count := jsonb_array_length(i_child_roots);
    IF NOT (v_count IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/children_must_be_array',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/children-must-be-array'
      ;
    END IF;
    IF NOT ("gw_ledger".roots_strictly_ordered(i_child_roots,0,v_count)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/unordered_set_children',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/unordered-set-children'
      ;
    END IF;
    v_prefix := ('T:' || v_count || ':');
    v_tail := "gw_ledger".sequence_payload_tail(i_child_roots,0,v_count);
    RETURN decode(v_prefix || v_tail,'escape');
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.codec-value/map-payload [130] 
CREATE OR REPLACE FUNCTION "gw_ledger".map_payload(
  i_child_roots JSONB
) RETURNS BYTEA AS $$

  DECLARE
    v_count INTEGER;
    v_prefix TEXT;
    v_tail TEXT;
  BEGIN
    v_count := jsonb_array_length(i_child_roots);
    IF NOT (v_count IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/children_must_be_array',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/children-must-be-array'
      ;
    END IF;
    IF NOT ((v_count % 2) = 0) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/uneven_map_children','data',null))::TEXT,
        MESSAGE = 'ledger/uneven-map-children'
      ;
    END IF;
    IF NOT ("gw_ledger".map_keys_strictly_ordered(i_child_roots,0,v_count)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/unordered_map_keys','data',null))::TEXT,
        MESSAGE = 'ledger/unordered-map-keys'
      ;
    END IF;
    v_prefix := ('M:' || (v_count / 2) || ':');
    v_tail := "gw_ledger".sequence_payload_tail(i_child_roots,0,v_count);
    RETURN decode(v_prefix || v_tail,'escape');
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.codec-value/syntax-payload [145] 
CREATE OR REPLACE FUNCTION "gw_ledger".syntax_payload(
  i_value_root BYTEA,
  i_metadata_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".sequence_payload(
    jsonb_build_array(encode(i_value_root,'hex'),encode(i_metadata_root,'hex'))
  );
END;
$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- gwdb.ledger.value/put-value [22] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_value(
  i_type_tag SMALLINT,
  i_payload BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_put(
    "gw_ledger".canonical_hash(i_type_tag,i_payload),
    1,
    i_type_tag,
    i_payload
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-nil [31] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_nil() RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_put(
    "gw_ledger".canonical_hash(0,decode('','hex')),
    1,
    0,
    decode('','hex')
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-boolean-payload [38] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_boolean_payload(
  i_payload BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_put("gw_ledger".canonical_hash(1,i_payload),1,1,i_payload);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-boolean [45] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_boolean(
  i_value BOOLEAN
) RETURNS BYTEA AS $$

  DECLARE
    v_payload BYTEA;
  BEGIN
    v_payload := CASE WHEN i_value THEN decode('01','hex')
    ELSE decode('00','hex')
    END;
    RETURN "gw_ledger".put_boolean_payload(v_payload);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-integer-payload [54] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_integer_payload(
  i_payload BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_put("gw_ledger".canonical_hash(2,i_payload),1,2,i_payload);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-integer [61] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_integer(
  i_value TEXT
) RETURNS BYTEA AS $$

  DECLARE
    v_payload BYTEA;
  BEGIN
    IF NOT (regexp_match(i_value,'^-?(0|[1-9][0-9]*)$') IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_integer_encoding',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-integer-encoding'
      ;
    END IF;
    v_payload := decode(i_value,'escape');
    RETURN "gw_ledger".put_integer_payload(v_payload);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-integer-number [70] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_integer_number(
  i_value BIGINT
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_integer((i_value)::TEXT);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/integer-bigint [76] 
CREATE OR REPLACE FUNCTION "gw_ledger".integer_bigint(
  i_root BYTEA
) RETURNS BIGINT AS $$

  DECLARE
    o_cell JSONB;
  BEGIN
    o_cell := "gw_ledger".cell_by_hash(i_root);
    IF NOT (o_cell IS NOT NULL AND ((o_cell ->> 'type_tag')::SMALLINT = 2)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/not_integer','data',null))::TEXT,
        MESSAGE = 'ledger/not-integer'
      ;
    END IF;
    RETURN (encode((o_cell ->> 'payload')::BYTEA,'escape'))::BIGINT;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-double [86] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_double(
  i_payload BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_put("gw_ledger".canonical_hash(3,i_payload),1,3,i_payload);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-character [93] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_character(
  i_payload BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_put("gw_ledger".canonical_hash(4,i_payload),1,4,i_payload);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-string-payload [100] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_string_payload(
  i_payload BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_put("gw_ledger".canonical_hash(5,i_payload),1,5,i_payload);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-string [107] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_string(
  i_value TEXT
) RETURNS BYTEA AS $$

  DECLARE
    v_payload BYTEA;
  BEGIN
    v_payload := convert_to(i_value,'UTF8');
    RETURN "gw_ledger".put_string_payload(v_payload);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-blob [114] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_blob(
  i_payload BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_put("gw_ledger".canonical_hash(6,i_payload),1,6,i_payload);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-symbol-payload [121] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_symbol_payload(
  i_payload BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_put("gw_ledger".canonical_hash(7,i_payload),1,7,i_payload);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-symbol [128] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_symbol(
  i_value TEXT
) RETURNS BYTEA AS $$

  DECLARE
    v_payload BYTEA;
  BEGIN
    v_payload := convert_to(i_value,'UTF8');
    RETURN "gw_ledger".put_symbol_payload(v_payload);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-keyword-payload [135] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_keyword_payload(
  i_payload BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_put("gw_ledger".canonical_hash(8,i_payload),1,8,i_payload);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-keyword [142] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_keyword(
  i_value TEXT
) RETURNS BYTEA AS $$

  DECLARE
    v_payload BYTEA;
  BEGIN
    v_payload := convert_to(i_value,'UTF8');
    RETURN "gw_ledger".put_keyword_payload(v_payload);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-list-payload [149] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_list_payload(
  i_payload BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_put("gw_ledger".canonical_hash(9,i_payload),1,9,i_payload);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/sequence-refs-put [156] 
CREATE OR REPLACE FUNCTION "gw_ledger".sequence_refs_put(
  i_parent_root BYTEA,
  i_child_roots JSONB,
  i_position INTEGER,
  i_count INTEGER
) RETURNS JSONB AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN null;
  ELSE
    DECLARE
    o_next JSONB;
      o_ref JSONB;
      v_child_hex TEXT;
      v_child_root BYTEA;
  BEGIN
    v_child_hex := (i_child_roots ->> i_position);
      v_child_root := decode(v_child_hex,'hex');
      o_ref := "gw_ledger".cell_ref_put(i_parent_root,i_position,'element',v_child_root);
      o_next := "gw_ledger".sequence_refs_put(i_parent_root,i_child_roots,i_position + 1,i_count);
      RETURN o_ref;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-list [170] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_list(
  i_child_roots JSONB
) RETURNS BYTEA AS $$

  DECLARE
    o_refs JSONB;
    v_count INTEGER;
    v_payload BYTEA;
    v_root BYTEA;
  BEGIN
    v_count := jsonb_array_length(i_child_roots);
    v_payload := "gw_ledger".sequence_payload(i_child_roots);
    v_root := "gw_ledger".put_list_payload(v_payload);
    o_refs := "gw_ledger".sequence_refs_put(v_root,i_child_roots,0,v_count);
    RETURN v_root;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-vector-payload [180] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_vector_payload(
  i_payload BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_put("gw_ledger".canonical_hash(10,i_payload),1,10,i_payload);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-vector [187] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_vector(
  i_child_roots JSONB
) RETURNS BYTEA AS $$

  DECLARE
    o_refs JSONB;
    v_count INTEGER;
    v_payload BYTEA;
    v_root BYTEA;
  BEGIN
    v_count := jsonb_array_length(i_child_roots);
    v_payload := "gw_ledger".sequence_payload(i_child_roots);
    v_root := "gw_ledger".put_vector_payload(v_payload);
    o_refs := "gw_ledger".sequence_refs_put(v_root,i_child_roots,0,v_count);
    RETURN v_root;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/VectorElement [197] 
DROP TABLE IF EXISTS "gw_ledger"."VectorElement" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."VectorElement" (
  "vector_root" BYTEA,
  "position" INTEGER,
  "value_root" BYTEA NOT NULL,
  PRIMARY KEY (vector_root,position)
);

-- gwdb.ledger.value/vector-element-put [204] 
CREATE OR REPLACE FUNCTION "gw_ledger".vector_element_put(
  i_vector_root BYTEA,
  i_position INTEGER,
  i_value_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_ref JSONB;
    o_row JSONB;
    o_value JSONB;
    o_vector JSONB;
  BEGIN
    o_vector := "gw_ledger".cell_by_hash(i_vector_root);
    o_value := "gw_ledger".cell_by_hash(i_value_root);
    IF NOT (o_vector IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_vector_cell','data',null))::TEXT,
        MESSAGE = 'ledger/missing-vector-cell'
      ;
    END IF;
    IF NOT ((o_vector ->> 'type_tag')::SMALLINT = 10) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/wrong_vector_type','data',null))::TEXT,
        MESSAGE = 'ledger/wrong-vector-type'
      ;
    END IF;
    IF NOT (i_position >= 0) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_vector_position',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-vector-position'
      ;
    END IF;
    IF NOT (o_value IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_vector_value','data',null))::TEXT,
        MESSAGE = 'ledger/missing-vector-value'
      ;
    END IF;
    o_ref := "gw_ledger".cell_ref_put(i_vector_root,i_position,'element',i_value_root);
    WITH j_ret AS (  
      INSERT INTO "gw_ledger"."VectorElement" ("vector_root","position","value_root") VALUES (
        (i_vector_root)::BYTEA,
        (i_position)::INTEGER,
        (i_value_root)::BYTEA
      ) ON CONFLICT ("vector_root","position") DO UPDATE SET ("vector_root","position","value_root") = row(
        EXCLUDED."vector_root",
        EXCLUDED."position",
        EXCLUDED."value_root"
      ) RETURNING "vector_root","position","value_root")
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/vector-element-get [225] 
CREATE OR REPLACE FUNCTION "gw_ledger".vector_element_get(
  i_vector_root BYTEA,
  i_position INTEGER
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT "vector_root","position","value_root" FROM "gw_ledger"."VectorElement"
      WHERE "vector_root" = i_vector_root AND "position" = i_position
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/vector-get [234] 
CREATE OR REPLACE FUNCTION "gw_ledger".vector_get(
  i_vector_root BYTEA,
  i_position INTEGER
) RETURNS BYTEA AS $$

  DECLARE
    o_vector JSONB;
    v_count INTEGER;
  BEGIN
    o_vector := "gw_ledger".cell_by_hash(i_vector_root);
    IF NOT (o_vector IS NOT NULL AND ((o_vector ->> 'type_tag')::SMALLINT = 10)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/not_vector','data',null))::TEXT,
        MESSAGE = 'ledger/not-vector'
      ;
    END IF;
    v_count := "gw_ledger".cell_ref_count(i_vector_root,'element');
    IF (i_position < 0) OR (i_position >= v_count) THEN
      RETURN null;
    ELSE
      RETURN "gw_ledger".cell_ref_child(i_vector_root,i_position,'element');
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-map-payload [248] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_map_payload(
  i_payload BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_put("gw_ledger".canonical_hash(11,i_payload),1,11,i_payload);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/map-refs-put [255] 
CREATE OR REPLACE FUNCTION "gw_ledger".map_refs_put(
  i_parent_root BYTEA,
  i_child_roots JSONB,
  i_position INTEGER,
  i_count INTEGER
) RETURNS JSONB AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN null;
  ELSE
    DECLARE
    o_key_ref JSONB;
      o_next JSONB;
      o_value_ref JSONB;
      v_key_hex TEXT;
      v_key_root BYTEA;
      v_value_hex TEXT;
      v_value_root BYTEA;
  BEGIN
    v_key_hex := (i_child_roots ->> i_position);
      v_value_hex := (i_child_roots ->> (i_position + 1));
      v_key_root := decode(v_key_hex,'hex');
      v_value_root := decode(v_value_hex,'hex');
      o_key_ref := "gw_ledger".cell_ref_put(i_parent_root,i_position / 2,'key',v_key_root);
      o_value_ref := "gw_ledger".cell_ref_put(i_parent_root,i_position / 2,'value',v_value_root);
      o_next := "gw_ledger".map_refs_put(i_parent_root,i_child_roots,i_position + 2,i_count);
      RETURN o_value_ref;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-map [274] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_map(
  i_child_roots JSONB
) RETURNS BYTEA AS $$

  DECLARE
    o_refs JSONB;
    v_count INTEGER;
    v_payload BYTEA;
    v_root BYTEA;
  BEGIN
    v_count := jsonb_array_length(i_child_roots);
    v_payload := "gw_ledger".map_payload(i_child_roots);
    v_root := "gw_ledger".put_map_payload(v_payload);
    o_refs := "gw_ledger".map_refs_put(v_root,i_child_roots,0,v_count);
    RETURN v_root;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/map-copy-tail [284] 
CREATE OR REPLACE FUNCTION "gw_ledger".map_copy_tail(
  i_map_root BYTEA,
  i_position INTEGER,
  i_count INTEGER,
  i_out JSONB
) RETURNS JSONB AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN i_out;
  ELSE
    DECLARE
    v_key BYTEA;
      v_next JSONB;
      v_value BYTEA;
  BEGIN
    v_key := "gw_ledger".cell_ref_child(i_map_root,i_position,'key');
      v_value := "gw_ledger".cell_ref_child(i_map_root,i_position,'value');
      v_next := (i_out || jsonb_build_array(encode(v_key,'hex'),encode(v_value,'hex')));
      RETURN "gw_ledger".map_copy_tail(i_map_root,i_position + 1,i_count,v_next);
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/map-assoc-roots [299] 
CREATE OR REPLACE FUNCTION "gw_ledger".map_assoc_roots(
  i_map_root BYTEA,
  i_key_root BYTEA,
  i_value_root BYTEA,
  i_position INTEGER,
  i_count INTEGER,
  i_out JSONB
) RETURNS JSONB AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN i_out || jsonb_build_array(encode(i_key_root,'hex'),encode(i_value_root,'hex'));
  ELSE
    DECLARE
    v_inserted JSONB;
      v_key BYTEA;
      v_order INTEGER;
      v_value BYTEA;
  BEGIN
    v_key := "gw_ledger".cell_ref_child(i_map_root,i_position,'key');
      v_value := "gw_ledger".cell_ref_child(i_map_root,i_position,'value');
      v_order := "gw_ledger".compare(i_key_root,v_key);
      v_inserted := (i_out || jsonb_build_array(encode(i_key_root,'hex'),encode(i_value_root,'hex')));
      IF v_order = 0 THEN
        RETURN "gw_ledger".map_copy_tail(i_map_root,i_position + 1,i_count,v_inserted);
      ELSIF v_order < 0 THEN
        RETURN "gw_ledger".map_copy_tail(i_map_root,i_position,i_count,v_inserted);
      ELSE
        DECLARE
        v_next JSONB;
      BEGIN
        v_next := (i_out || jsonb_build_array(encode(v_key,'hex'),encode(v_value,'hex')));
          RETURN "gw_ledger".map_assoc_roots(i_map_root,i_key_root,i_value_root,i_position + 1,i_count,v_next);
      END;
      END IF;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/map-assoc [334] 
CREATE OR REPLACE FUNCTION "gw_ledger".map_assoc(
  i_map_root BYTEA,
  i_key_root BYTEA,
  i_value_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_map JSONB;
    v_count INTEGER;
    v_roots JSONB;
  BEGIN
    o_map := "gw_ledger".cell_by_hash(i_map_root);
    IF NOT (o_map IS NOT NULL AND ((o_map ->> 'type_tag')::SMALLINT = 11)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/not_map','data',null))::TEXT,
        MESSAGE = 'ledger/not-map'
      ;
    END IF;
    v_count := "gw_ledger".cell_ref_count(i_map_root,'key');
    v_roots := "gw_ledger".map_assoc_roots(i_map_root,i_key_root,i_value_root,0,v_count,jsonb_build_array());
    RETURN "gw_ledger".put_map(v_roots);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/map-get-at [348] 
CREATE OR REPLACE FUNCTION "gw_ledger".map_get_at(
  i_map_root BYTEA,
  i_key_root BYTEA,
  i_position INTEGER,
  i_count INTEGER
) RETURNS BYTEA AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN null;
  ELSE
    DECLARE
    v_key BYTEA;
      v_order INTEGER;
  BEGIN
    v_key := "gw_ledger".cell_ref_child(i_map_root,i_position,'key');
      v_order := "gw_ledger".compare(i_key_root,v_key);
      IF v_order = 0 THEN
        RETURN "gw_ledger".cell_ref_child(i_map_root,i_position,'value');
      ELSIF v_order < 0 THEN
        RETURN null;
      ELSE
        RETURN "gw_ledger".map_get_at(i_map_root,i_key_root,i_position + 1,i_count);
      END IF;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/map-get [365] 
CREATE OR REPLACE FUNCTION "gw_ledger".map_get(
  i_map_root BYTEA,
  i_key_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_map JSONB;
    v_count INTEGER;
  BEGIN
    o_map := "gw_ledger".cell_by_hash(i_map_root);
    IF NOT (o_map IS NOT NULL AND ((o_map ->> 'type_tag')::SMALLINT = 11)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/not_map','data',null))::TEXT,
        MESSAGE = 'ledger/not-map'
      ;
    END IF;
    v_count := "gw_ledger".cell_ref_count(i_map_root,'key');
    RETURN "gw_ledger".map_get_at(i_map_root,i_key_root,0,v_count);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/set-contains-at [376] 
CREATE OR REPLACE FUNCTION "gw_ledger".set_contains_at(
  i_set_root BYTEA,
  i_value_root BYTEA,
  i_position INTEGER,
  i_count INTEGER
) RETURNS BOOLEAN AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN false;
  ELSE
    DECLARE
    v_current BYTEA;
      v_order INTEGER;
  BEGIN
    v_current := "gw_ledger".cell_ref_child(i_set_root,i_position,'element');
      v_order := "gw_ledger".compare(i_value_root,v_current);
      IF v_order = 0 THEN
        RETURN true;
      ELSIF v_order < 0 THEN
        RETURN false;
      ELSE
        RETURN "gw_ledger".set_contains_at(i_set_root,i_value_root,i_position + 1,i_count);
      END IF;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/set-contains [391] 
CREATE OR REPLACE FUNCTION "gw_ledger".set_contains(
  i_set_root BYTEA,
  i_value_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_set JSONB;
    v_count INTEGER;
  BEGIN
    o_set := "gw_ledger".cell_by_hash(i_set_root);
    IF NOT (o_set IS NOT NULL AND ((o_set ->> 'type_tag')::SMALLINT = 12)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/not_set','data',null))::TEXT,
        MESSAGE = 'ledger/not-set'
      ;
    END IF;
    v_count := "gw_ledger".cell_ref_count(i_set_root,'element');
    RETURN "gw_ledger".set_contains_at(i_set_root,i_value_root,0,v_count);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-set-payload [402] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_set_payload(
  i_payload BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_put("gw_ledger".canonical_hash(12,i_payload),1,12,i_payload);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-set [409] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_set(
  i_child_roots JSONB
) RETURNS BYTEA AS $$

  DECLARE
    o_refs JSONB;
    v_count INTEGER;
    v_payload BYTEA;
    v_root BYTEA;
  BEGIN
    v_count := jsonb_array_length(i_child_roots);
    v_payload := "gw_ledger".set_payload(i_child_roots);
    v_root := "gw_ledger".put_set_payload(v_payload);
    o_refs := "gw_ledger".sequence_refs_put(v_root,i_child_roots,0,v_count);
    RETURN v_root;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-record [419] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_record(
  i_payload BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_put("gw_ledger".canonical_hash(14,i_payload),1,14,i_payload);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.value/put-reference [426] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_reference(
  i_payload BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_put("gw_ledger".canonical_hash(15,i_payload),1,15,i_payload);
END;
$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- gwdb.ledger.account/Account [18] 
DROP TABLE IF EXISTS "gw_ledger"."Account" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."Account" (
  "address" BYTEA PRIMARY KEY,
  "sequence" BIGINT NOT NULL,
  "state_root" BYTEA NOT NULL,
  "environment_root" BYTEA NOT NULL,
  "metadata_root" BYTEA NOT NULL,
  "controller" BYTEA,
  "created_at" BIGINT NOT NULL DEFAULT (1000000 * extract(epoch FROM now()))::BIGINT
);

-- gwdb.ledger.account/Definition [30] 
DROP TABLE IF EXISTS "gw_ledger"."Definition" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."Definition" (
  "address" BYTEA,
  "symbol_root" BYTEA,
  "value_root" BYTEA NOT NULL,
  "state_root" BYTEA NOT NULL,
  "created_at" BIGINT NOT NULL DEFAULT (1000000 * extract(epoch FROM now()))::BIGINT,
  PRIMARY KEY (address,symbol_root)
);

-- gwdb.ledger.account/account-value-payload [40] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_payload(
  i_sequence_root BYTEA,
  i_environment_root BYTEA,
  i_metadata_root BYTEA,
  i_controller_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN decode(
    'R:account:1:4:' || encode(i_sequence_root,'hex') || encode(i_environment_root,'hex') || encode(i_metadata_root,'hex') || encode(i_controller_root,'hex'),
    'escape'
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-put [56] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_put(
  i_sequence_root BYTEA,
  i_environment_root BYTEA,
  i_metadata_root BYTEA,
  i_controller_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_controller JSONB;
    o_controller_ref JSONB;
    o_environment JSONB;
    o_environment_ref JSONB;
    o_metadata JSONB;
    o_metadata_ref JSONB;
    o_sequence JSONB;
    o_sequence_ref JSONB;
    v_payload BYTEA;
    v_root BYTEA;
  BEGIN
    o_sequence := "gw_ledger".cell_by_hash(i_sequence_root);
    o_environment := "gw_ledger".cell_by_hash(i_environment_root);
    o_metadata := "gw_ledger".cell_by_hash(i_metadata_root);
    o_controller := "gw_ledger".cell_by_hash(i_controller_root);
    IF NOT (o_sequence IS NOT NULL AND ((o_sequence ->> 'type_tag')::SMALLINT = 2)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/account_sequence_not_integer',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/account-sequence-not-integer'
      ;
    END IF;
    IF NOT (o_environment IS NOT NULL AND ((o_environment ->> 'type_tag')::SMALLINT = 11)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/account_environment_not_map',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/account-environment-not-map'
      ;
    END IF;
    IF NOT (o_metadata IS NOT NULL AND ((o_metadata ->> 'type_tag')::SMALLINT = 11)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/account_metadata_not_map',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/account-metadata-not-map'
      ;
    END IF;
    IF NOT (o_controller IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_account_controller',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-account-controller'
      ;
    END IF;
    v_payload := "gw_ledger".account_value_payload(
      i_sequence_root,
      i_environment_root,
      i_metadata_root,
      i_controller_root
    );
    v_root := "gw_ledger".cell_put("gw_ledger".canonical_hash(14,v_payload),1,14,v_payload);
    o_sequence_ref := "gw_ledger".cell_ref_put(v_root,0,'sequence',i_sequence_root);
    o_environment_ref := "gw_ledger".cell_ref_put(v_root,1,'environment',i_environment_root);
    o_metadata_ref := "gw_ledger".cell_ref_put(v_root,2,'metadata',i_metadata_root);
    o_controller_ref := "gw_ledger".cell_ref_put(v_root,3,'controller',i_controller_root);
    RETURN v_root;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-create [89] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_create(
  i_controller_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_environment BYTEA;
    v_metadata BYTEA;
    v_sequence BYTEA;
  BEGIN
    v_sequence := "gw_ledger".put_integer('0');
    v_environment := "gw_ledger".put_map(jsonb_build_array());
    v_metadata := "gw_ledger".put_map(jsonb_build_array());
    RETURN "gw_ledger".account_value_put(v_sequence,v_environment,v_metadata,i_controller_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-sequence-root [99] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_sequence_root(
  i_account_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_ref_child(i_account_root,0,'sequence');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-environment-root [104] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_environment_root(
  i_account_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_ref_child(i_account_root,1,'environment');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-metadata-root [109] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_metadata_root(
  i_account_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_ref_child(i_account_root,2,'metadata');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-controller-root [114] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_controller_root(
  i_account_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_ref_child(i_account_root,3,'controller');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-define-empty [119] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_define_empty(
  i_account_root BYTEA,
  i_symbol_root BYTEA,
  i_value_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_environment BYTEA;
    v_next_environment BYTEA;
  BEGIN
    v_environment := "gw_ledger".account_value_environment_root(i_account_root);
    v_next_environment := "gw_ledger".map_assoc(v_environment,i_symbol_root,i_value_root);
    RETURN "gw_ledger".account_value_put(
      "gw_ledger".account_value_sequence_root(i_account_root),
      v_next_environment,
      "gw_ledger".account_value_metadata_root(i_account_root),
      "gw_ledger".account_value_controller_root(i_account_root)
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-define [135] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_define(
  i_account_root BYTEA,
  i_symbol_root BYTEA,
  i_value_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".account_value_define_empty(i_account_root,i_symbol_root,i_value_root);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-advance-sequence [141] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_advance_sequence(
  i_account_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_next_sequence BYTEA;
    v_sequence BIGINT;
    v_sequence_root BYTEA;
  BEGIN
    v_sequence_root := "gw_ledger".account_value_sequence_root(i_account_root);
    v_sequence := "gw_ledger".integer_bigint(v_sequence_root);
    v_next_sequence := "gw_ledger".put_integer_number(v_sequence + 1);
    RETURN "gw_ledger".account_value_put(
      v_next_sequence,
      "gw_ledger".account_value_environment_root(i_account_root),
      "gw_ledger".account_value_metadata_root(i_account_root),
      "gw_ledger".account_value_controller_root(i_account_root)
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-lookup [154] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_lookup(
  i_account_root BYTEA,
  i_symbol_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".map_get(
    "gw_ledger".account_value_environment_root(i_account_root),
    i_symbol_root
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-get [161] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_get(
  i_address BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT
        "address",
        "sequence",
        "state_root",
        "environment_root",
        "metadata_root",
        "controller",
        "created_at"
      FROM "gw_ledger"."Account"
      WHERE "address" = i_address
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-put [169] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_put(
  i_address BYTEA,
  i_sequence BIGINT,
  i_state_root BYTEA,
  i_environment_root BYTEA,
  i_metadata_root BYTEA,
  i_controller BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      INSERT INTO "gw_ledger"."Account" (
        "address",
        "sequence",
        "state_root",
        "environment_root",
        "metadata_root",
        "controller"
      ) VALUES (
        (i_address)::BYTEA,
        (i_sequence)::BIGINT,
        (i_state_root)::BYTEA,
        (i_environment_root)::BYTEA,
        (i_metadata_root)::BYTEA,
        (i_controller)::BYTEA
      ) ON CONFLICT ("address") DO UPDATE SET ("address",
        "sequence",
        "state_root",
        "environment_root",
        "metadata_root",
        "controller") = row(
        EXCLUDED."address",
        EXCLUDED."sequence",
        EXCLUDED."state_root",
        EXCLUDED."environment_root",
        EXCLUDED."metadata_root",
        EXCLUDED."controller"
      ) RETURNING
        "address",
        "sequence",
        "state_root",
        "environment_root",
        "metadata_root",
        "controller",
        "created_at")
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-sequence [188] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_sequence(
  i_address BYTEA
) RETURNS BIGINT AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    o_row := "gw_ledger".account_get(i_address);
    IF o_row is not null  THEN
      RETURN (o_row ->> 'sequence')::BIGINT;
    ELSE
      RETURN 0;
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-environment [198] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_environment(
  i_address BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    o_row := "gw_ledger".account_get(i_address);
    RETURN (o_row ->> 'environment_root')::BYTEA;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-metadata [205] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_metadata(
  i_address BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    o_row := "gw_ledger".account_get(i_address);
    RETURN (o_row ->> 'metadata_root')::BYTEA;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-lookup [212] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_lookup(
  i_address BYTEA
) RETURNS JSONB AS $$
BEGIN
  RETURN "gw_ledger".account_get(i_address);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-create [218] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_create(
  i_address BYTEA,
  i_state_root BYTEA,
  i_environment_root BYTEA,
  i_metadata_root BYTEA,
  i_controller BYTEA
) RETURNS JSONB AS $$
BEGIN
  RETURN "gw_ledger".account_put(
    i_address,
    0,
    i_state_root,
    i_environment_root,
    i_metadata_root,
    i_controller
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-define [229] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_define(
  i_address BYTEA,
  i_sequence BIGINT,
  i_state_root BYTEA,
  i_environment_root BYTEA,
  i_metadata_root BYTEA,
  i_controller BYTEA
) RETURNS JSONB AS $$
BEGIN
  RETURN "gw_ledger".account_put(
    i_address,
    i_sequence,
    i_state_root,
    i_environment_root,
    i_metadata_root,
    i_controller
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-set-metadata [241] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_set_metadata(
  i_address BYTEA,
  i_sequence BIGINT,
  i_state_root BYTEA,
  i_environment_root BYTEA,
  i_metadata_root BYTEA,
  i_controller BYTEA
) RETURNS JSONB AS $$
BEGIN
  RETURN "gw_ledger".account_put(
    i_address,
    i_sequence,
    i_state_root,
    i_environment_root,
    i_metadata_root,
    i_controller
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/definition-put [253] 
CREATE OR REPLACE FUNCTION "gw_ledger".definition_put(
  i_address BYTEA,
  i_symbol_root BYTEA,
  i_value_root BYTEA,
  i_state_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      INSERT INTO "gw_ledger"."Definition" ("address","symbol_root","value_root","state_root") VALUES (
        (i_address)::BYTEA,
        (i_symbol_root)::BYTEA,
        (i_value_root)::BYTEA,
        (i_state_root)::BYTEA
      ) ON CONFLICT ("address","symbol_root") DO UPDATE SET ("address","symbol_root","value_root","state_root") = row(
        EXCLUDED."address",
        EXCLUDED."symbol_root",
        EXCLUDED."value_root",
        EXCLUDED."state_root"
      ) RETURNING "address","symbol_root","value_root","state_root","created_at")
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/definition-get [267] 
CREATE OR REPLACE FUNCTION "gw_ledger".definition_get(
  i_address BYTEA,
  i_symbol_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT "address","symbol_root","value_root","state_root","created_at" FROM "gw_ledger"."Definition"
      WHERE "address" = i_address AND "symbol_root" = i_symbol_root
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-advance-sequence [276] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_advance_sequence(
  i_address BYTEA,
  i_expected_sequence BIGINT
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    o_row := "gw_ledger".account_get(i_address);
    IF NOT (o_row IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_account','data',null))::TEXT,
        MESSAGE = 'ledger/missing-account'
      ;
    END IF;
    IF NOT ((o_row ->> 'sequence')::BIGINT = i_expected_sequence) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/sequence_conflict','data',null))::TEXT,
        MESSAGE = 'ledger/sequence-conflict'
      ;
    END IF;
    RETURN "gw_ledger".account_put(
      i_address,
      i_expected_sequence + 1,
      (o_row ->> 'state_root')::BYTEA,
      (o_row ->> 'environment_root')::BYTEA,
      (o_row ->> 'metadata_root')::BYTEA,
      (o_row ->> 'controller')::BYTEA
    );
  END;

$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- gwdb.ledger.state/StateHead [24] 
DROP TABLE IF EXISTS "gw_ledger"."StateHead" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."StateHead" (
  "state_root" BYTEA PRIMARY KEY,
  "state_version" SMALLINT NOT NULL,
  "block_height" BIGINT NOT NULL,
  "created_at" BIGINT NOT NULL DEFAULT (1000000 * extract(epoch FROM now()))::BIGINT
);

-- gwdb.ledger.state/state-payload [33] 
CREATE OR REPLACE FUNCTION "gw_ledger".state_payload(
  i_version_root BYTEA,
  i_accounts_root BYTEA,
  i_modules_root BYTEA,
  i_module_aliases_root BYTEA,
  i_validators_root BYTEA,
  i_settings_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN decode(
    'R:state:1:6:' || encode(i_version_root,'hex') || encode(i_accounts_root,'hex') || encode(i_modules_root,'hex') || encode(i_module_aliases_root,'hex') || encode(i_validators_root,'hex') || encode(i_settings_root,'hex'),
    'escape'
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.state/state-put [53] 
CREATE OR REPLACE FUNCTION "gw_ledger".state_put(
  i_version_root BYTEA,
  i_accounts_root BYTEA,
  i_modules_root BYTEA,
  i_module_aliases_root BYTEA,
  i_validators_root BYTEA,
  i_settings_root BYTEA,
  i_block_height BIGINT
) RETURNS BYTEA AS $$

  DECLARE
    o_accounts JSONB;
    o_accounts_ref JSONB;
    o_aliases JSONB;
    o_aliases_ref JSONB;
    o_head JSONB;
    o_modules JSONB;
    o_modules_ref JSONB;
    o_settings JSONB;
    o_settings_ref JSONB;
    o_validators JSONB;
    o_validators_ref JSONB;
    o_version JSONB;
    o_version_ref JSONB;
    v_payload BYTEA;
    v_root BYTEA;
  BEGIN
    o_version := "gw_ledger".cell_by_hash(i_version_root);
    o_accounts := "gw_ledger".cell_by_hash(i_accounts_root);
    o_modules := "gw_ledger".cell_by_hash(i_modules_root);
    o_aliases := "gw_ledger".cell_by_hash(i_module_aliases_root);
    o_validators := "gw_ledger".cell_by_hash(i_validators_root);
    o_settings := "gw_ledger".cell_by_hash(i_settings_root);
    IF NOT (o_version IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_state_version',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-state-version'
      ;
    END IF;
    IF NOT ((o_version ->> 'type_tag')::SMALLINT = 2) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/state_version_not_integer',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/state-version-not-integer'
      ;
    END IF;
    IF NOT (o_accounts IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_state_accounts',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-state-accounts'
      ;
    END IF;
    IF NOT (o_modules IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_state_modules',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-state-modules'
      ;
    END IF;
    IF NOT (o_aliases IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_state_module_aliases',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-state-module-aliases'
      ;
    END IF;
    IF NOT (o_validators IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_state_validators',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-state-validators'
      ;
    END IF;
    IF NOT (o_settings IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_state_settings',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-state-settings'
      ;
    END IF;
    IF NOT ((o_accounts ->> 'type_tag')::SMALLINT = 11) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/state_accounts_not_map',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/state-accounts-not-map'
      ;
    END IF;
    IF NOT ((o_modules ->> 'type_tag')::SMALLINT = 11) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/state_modules_not_map',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/state-modules-not-map'
      ;
    END IF;
    IF NOT ((o_aliases ->> 'type_tag')::SMALLINT = 11) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/state_module_aliases_not_map',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/state-module-aliases-not-map'
      ;
    END IF;
    IF NOT ((o_validators ->> 'type_tag')::SMALLINT = 11) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/state_validators_not_map',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/state-validators-not-map'
      ;
    END IF;
    IF NOT ((o_settings ->> 'type_tag')::SMALLINT = 11) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/state_settings_not_map',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/state-settings-not-map'
      ;
    END IF;
    v_payload := "gw_ledger".state_payload(
      i_version_root,
      i_accounts_root,
      i_modules_root,
      i_module_aliases_root,
      i_validators_root,
      i_settings_root
    );
    v_root := "gw_ledger".cell_put("gw_ledger".canonical_hash(14,v_payload),1,14,v_payload);
    o_version_ref := "gw_ledger".cell_ref_put(v_root,0,'state/version',i_version_root);
    o_accounts_ref := "gw_ledger".cell_ref_put(v_root,1,'accounts',i_accounts_root);
    o_modules_ref := "gw_ledger".cell_ref_put(v_root,2,'modules',i_modules_root);
    o_aliases_ref := "gw_ledger".cell_ref_put(v_root,3,'module-aliases',i_module_aliases_root);
    o_validators_ref := "gw_ledger".cell_ref_put(v_root,4,'validators',i_validators_root);
    o_settings_ref := "gw_ledger".cell_ref_put(v_root,5,'settings',i_settings_root);
    WITH j_ret AS (  
      INSERT INTO "gw_ledger"."StateHead" ("state_root","state_version","block_height") VALUES ((v_root)::BYTEA,(1)::SMALLINT,(i_block_height)::BIGINT) ON CONFLICT ("state_root") DO UPDATE SET ("state_root","state_version","block_height") = row(
        EXCLUDED."state_root",
        EXCLUDED."state_version",
        EXCLUDED."block_height"
      ) RETURNING "state_root","state_version","block_height","created_at")
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_head;
    RETURN v_root;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.state/state-root-valid [104] 
CREATE OR REPLACE FUNCTION "gw_ledger".state_root_valid(
  i_state_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_cell JSONB;
    v_accounts BYTEA;
    v_aliases BYTEA;
    v_modules BYTEA;
    v_settings BYTEA;
    v_validators BYTEA;
    v_version BYTEA;
  BEGIN
    o_cell := "gw_ledger".cell_by_hash(i_state_root);
    IF o_cell is null  THEN
      RETURN false;
    END IF;
    v_version := "gw_ledger".cell_ref_child(i_state_root,0,'state/version');
    v_accounts := "gw_ledger".cell_ref_child(i_state_root,1,'accounts');
    v_modules := "gw_ledger".cell_ref_child(i_state_root,2,'modules');
    v_aliases := "gw_ledger".cell_ref_child(i_state_root,3,'module-aliases');
    v_validators := "gw_ledger".cell_ref_child(i_state_root,4,'validators');
    v_settings := "gw_ledger".cell_ref_child(i_state_root,5,'settings');
    RETURN ((o_cell ->> 'type_tag')::SMALLINT = 14) AND "gw_ledger".verify(i_state_root,14,(o_cell ->> 'payload')::BYTEA) AND ((o_cell ->> 'payload')::BYTEA = "gw_ledger".state_payload(v_version,v_accounts,v_modules,v_aliases,v_validators,v_settings)) AND ("gw_ledger".cell_ref_count(i_state_root,'state/version') = 1) AND ("gw_ledger".cell_ref_count(i_state_root,'accounts') = 1) AND ("gw_ledger".cell_ref_count(i_state_root,'modules') = 1) AND ("gw_ledger".cell_ref_count(i_state_root,'module-aliases') = 1) AND ("gw_ledger".cell_ref_count(i_state_root,'validators') = 1) AND ("gw_ledger".cell_ref_count(i_state_root,'settings') = 1);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.state/state-get [128] 
CREATE OR REPLACE FUNCTION "gw_ledger".state_get(
  i_state_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT "state_root","state_version","block_height","created_at" FROM "gw_ledger"."StateHead"
      WHERE "state_root" = i_state_root
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.state/state-version-root [135] 
CREATE OR REPLACE FUNCTION "gw_ledger".state_version_root(
  i_state_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_ref_child(i_state_root,0,'state/version');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.state/state-accounts-root [140] 
CREATE OR REPLACE FUNCTION "gw_ledger".state_accounts_root(
  i_state_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_ref_child(i_state_root,1,'accounts');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.state/state-modules-root [145] 
CREATE OR REPLACE FUNCTION "gw_ledger".state_modules_root(
  i_state_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_ref_child(i_state_root,2,'modules');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.state/state-module-aliases-root [150] 
CREATE OR REPLACE FUNCTION "gw_ledger".state_module_aliases_root(
  i_state_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_ref_child(i_state_root,3,'module-aliases');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.state/state-validators-root [155] 
CREATE OR REPLACE FUNCTION "gw_ledger".state_validators_root(
  i_state_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_ref_child(i_state_root,4,'validators');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.state/state-settings-root [160] 
CREATE OR REPLACE FUNCTION "gw_ledger".state_settings_root(
  i_state_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_ref_child(i_state_root,5,'settings');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.state/state-rebuild-head [165] 
CREATE OR REPLACE FUNCTION "gw_ledger".state_rebuild_head(
  i_state_root BYTEA,
  i_block_height BIGINT
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
    v_rebuilt BYTEA;
  BEGIN
    IF NOT ("gw_ledger".state_root_valid(i_state_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_state_root','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-state-root'
      ;
    END IF;
    v_rebuilt := "gw_ledger".state_put(
      "gw_ledger".state_version_root(i_state_root),
      "gw_ledger".state_accounts_root(i_state_root),
      "gw_ledger".state_modules_root(i_state_root),
      "gw_ledger".state_module_aliases_root(i_state_root),
      "gw_ledger".state_validators_root(i_state_root),
      "gw_ledger".state_settings_root(i_state_root),
      i_block_height
    );
    IF NOT (v_rebuilt = i_state_root) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/state_rebuild_mismatch',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/state-rebuild-mismatch'
      ;
    END IF;
    o_row := "gw_ledger".state_get(i_state_root);
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.state/state-genesis [185] 
CREATE OR REPLACE FUNCTION "gw_ledger".state_genesis() RETURNS BYTEA AS $$

  DECLARE
    v_accounts BYTEA;
    v_aliases BYTEA;
    v_modules BYTEA;
    v_settings BYTEA;
    v_validators BYTEA;
    v_version BYTEA;
  BEGIN
    v_version := "gw_ledger".put_integer('1');
    v_accounts := "gw_ledger".put_map(jsonb_build_array());
    v_modules := "gw_ledger".put_map(jsonb_build_array());
    v_aliases := "gw_ledger".put_map(jsonb_build_array());
    v_validators := "gw_ledger".put_map(jsonb_build_array());
    v_settings := "gw_ledger".put_map(jsonb_build_array());
    RETURN "gw_ledger".state_put(
      v_version,
      v_accounts,
      v_modules,
      v_aliases,
      v_validators,
      v_settings,
      0
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.state/state-with-accounts [198] 
CREATE OR REPLACE FUNCTION "gw_ledger".state_with_accounts(
  i_state_root BYTEA,
  i_accounts_root BYTEA,
  i_block_height BIGINT
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".state_put(
    "gw_ledger".state_version_root(i_state_root),
    i_accounts_root,
    "gw_ledger".state_modules_root(i_state_root),
    "gw_ledger".state_module_aliases_root(i_state_root),
    "gw_ledger".state_validators_root(i_state_root),
    "gw_ledger".state_settings_root(i_state_root),
    i_block_height
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.state/state-assoc-account [210] 
CREATE OR REPLACE FUNCTION "gw_ledger".state_assoc_account(
  i_state_root BYTEA,
  i_address_root BYTEA,
  i_account_root BYTEA,
  i_block_height BIGINT
) RETURNS BYTEA AS $$

  DECLARE
    v_accounts BYTEA;
  BEGIN
    v_accounts := "gw_ledger".map_assoc(
      "gw_ledger".state_accounts_root(i_state_root),
      i_address_root,
      i_account_root
    );
    RETURN "gw_ledger".state_with_accounts(i_state_root,v_accounts,i_block_height);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.state/state-account-root [223] 
CREATE OR REPLACE FUNCTION "gw_ledger".state_account_root(
  i_state_root BYTEA,
  i_address_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".map_get("gw_ledger".state_accounts_root(i_state_root),i_address_root);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.state/state-advance-account-sequence [229] 
CREATE OR REPLACE FUNCTION "gw_ledger".state_advance_account_sequence(
  i_state_root BYTEA,
  i_address_root BYTEA,
  i_block_height BIGINT
) RETURNS BYTEA AS $$

  DECLARE
    v_account_root BYTEA;
    v_next_account BYTEA;
  BEGIN
    v_account_root := "gw_ledger".state_account_root(i_state_root,i_address_root);
    IF NOT (v_account_root IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_account','data',null))::TEXT,
        MESSAGE = 'ledger/missing-account'
      ;
    END IF;
    v_next_account := "gw_ledger".account_value_advance_sequence(v_account_root);
    RETURN "gw_ledger".state_assoc_account(i_state_root,i_address_root,v_next_account,i_block_height);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.state/state-export [239] 
CREATE OR REPLACE FUNCTION "gw_ledger".state_export(
  i_state_root BYTEA
) RETURNS JSONB AS $$

  BEGIN
    IF NOT ("gw_ledger".state_root_valid(i_state_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_state_root','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-state-root'
      ;
    END IF;
    RETURN jsonb_build_object(
      'state/version',
      1,
      'state/root',
      encode(i_state_root,'hex'),
      'accounts/root',
      encode("gw_ledger".state_accounts_root(i_state_root),'hex'),
      'modules/root',
      encode("gw_ledger".state_modules_root(i_state_root),'hex'),
      'module-aliases/root',
      encode("gw_ledger".state_module_aliases_root(i_state_root),'hex'),
      'validators/root',
      encode("gw_ledger".state_validators_root(i_state_root),'hex'),
      'settings/root',
      encode("gw_ledger".state_settings_root(i_state_root),'hex')
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.state/state-import [255] 
CREATE OR REPLACE FUNCTION "gw_ledger".state_import(
  i_export JSONB,
  i_block_height BIGINT
) RETURNS BYTEA AS $$

  DECLARE
    v_accounts BYTEA;
    v_aliases BYTEA;
    v_imported BYTEA;
    v_modules BYTEA;
    v_root BYTEA;
    v_settings BYTEA;
    v_validators BYTEA;
  BEGIN
    v_root := decode((i_export ->> 'state/root')::TEXT,'hex');
    v_accounts := decode((i_export ->> 'accounts/root')::TEXT,'hex');
    v_modules := decode((i_export ->> 'modules/root')::TEXT,'hex');
    v_aliases := decode((i_export ->> 'module-aliases/root')::TEXT,'hex');
    v_validators := decode((i_export ->> 'validators/root')::TEXT,'hex');
    v_settings := decode((i_export ->> 'settings/root')::TEXT,'hex');
    IF NOT ((i_export ->> 'state/version')::INTEGER = 1) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/unsupported_state_export',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/unsupported-state-export'
      ;
    END IF;
    IF NOT ("gw_ledger".state_root_valid(v_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_exported_state',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-exported-state'
      ;
    END IF;
    v_imported := "gw_ledger".state_put(
      "gw_ledger".state_version_root(v_root),
      v_accounts,
      v_modules,
      v_aliases,
      v_validators,
      v_settings,
      i_block_height
    );
    IF NOT (v_imported = v_root) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/state_export_mismatch',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/state-export-mismatch'
      ;
    END IF;
    RETURN v_imported;
  END;

$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- gwdb.ledger.context/ExecutionContext [18] 
DROP TABLE IF EXISTS "gw_ledger"."ExecutionContext" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."ExecutionContext" (
  "context_root" BYTEA PRIMARY KEY,
  "state_root" BYTEA NOT NULL,
  "origin" BYTEA NOT NULL,
  "address" BYTEA NOT NULL,
  "caller" BYTEA,
  "transaction_root" BYTEA,
  "block_height" BIGINT NOT NULL,
  "timestamp" BIGINT NOT NULL,
  "locals_root" BYTEA NOT NULL,
  "cost_used" BIGINT NOT NULL,
  "cost_limit" BIGINT NOT NULL,
  "depth" INTEGER NOT NULL
);

-- gwdb.ledger.context/context-root-hex [34] 
CREATE OR REPLACE FUNCTION "gw_ledger".context_root_hex(
  i_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN CASE WHEN i_root IS NULL THEN '-'
  ELSE encode(i_root,'hex')
  END;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.context/context-payload [41] 
CREATE OR REPLACE FUNCTION "gw_ledger".context_payload(
  i_state_root BYTEA,
  i_origin BYTEA,
  i_address BYTEA,
  i_caller BYTEA,
  i_transaction_root BYTEA,
  i_block_height BIGINT,
  i_timestamp BIGINT,
  i_locals_root BYTEA,
  i_cost_used BIGINT,
  i_cost_limit BIGINT,
  i_depth INTEGER
) RETURNS BYTEA AS $$
BEGIN
  RETURN decode(
    'R:context:1:12:' || "gw_ledger".context_root_hex(i_state_root) || "gw_ledger".context_root_hex(i_origin) || "gw_ledger".context_root_hex(i_address) || "gw_ledger".context_root_hex(i_caller) || "gw_ledger".context_root_hex(i_transaction_root) || i_block_height || ':' || i_timestamp || ':' || "gw_ledger".context_root_hex(i_locals_root) || (i_cost_used)::TEXT || ':' || (i_cost_limit)::TEXT || ':' || (i_depth)::TEXT,
    'escape'
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.context/context-create [61] 
CREATE OR REPLACE FUNCTION "gw_ledger".context_create(
  i_state_root BYTEA,
  i_origin BYTEA,
  i_address BYTEA,
  i_caller BYTEA,
  i_transaction_root BYTEA,
  i_block_height BIGINT,
  i_timestamp BIGINT,
  i_locals_root BYTEA,
  i_cost_used BIGINT,
  i_cost_limit BIGINT,
  i_depth INTEGER
) RETURNS BYTEA AS $$

  DECLARE
    o_address JSONB;
    o_address_ref JSONB;
    o_locals JSONB;
    o_locals_ref JSONB;
    o_origin JSONB;
    o_origin_ref JSONB;
    o_row JSONB;
    o_state_ref JSONB;
    v_payload BYTEA;
    v_root BYTEA;
  BEGIN
    o_origin := "gw_ledger".cell_by_hash(i_origin);
    o_address := "gw_ledger".cell_by_hash(i_address);
    o_locals := "gw_ledger".cell_by_hash(i_locals_root);
    IF NOT ("gw_ledger".state_root_valid(i_state_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_context_state',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-context-state'
      ;
    END IF;
    IF NOT (o_origin IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_context_origin',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-context-origin'
      ;
    END IF;
    IF NOT (o_address IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_context_address',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-context-address'
      ;
    END IF;
    IF NOT (o_locals IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_context_locals',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-context-locals'
      ;
    END IF;
    IF NOT ((o_locals ->> 'type_tag')::SMALLINT = 10) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/context_locals_not_vector',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/context-locals-not-vector'
      ;
    END IF;
    IF NOT ((i_block_height >= 0) AND (i_timestamp >= 0) AND (i_cost_used >= 0) AND (i_cost_limit >= i_cost_used) AND (i_depth >= 0)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_context_bounds',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-context-bounds'
      ;
    END IF;
    v_payload := "gw_ledger".context_payload(
      i_state_root,
      i_origin,
      i_address,
      i_caller,
      i_transaction_root,
      i_block_height,
      i_timestamp,
      i_locals_root,
      i_cost_used,
      i_cost_limit,
      i_depth
    );
    v_root := "gw_ledger".cell_put("gw_ledger".canonical_hash(14,v_payload),1,14,v_payload);
    o_state_ref := "gw_ledger".cell_ref_put(v_root,0,'state',i_state_root);
    o_origin_ref := "gw_ledger".cell_ref_put(v_root,1,'origin',i_origin);
    o_address_ref := "gw_ledger".cell_ref_put(v_root,2,'address',i_address);
    o_locals_ref := "gw_ledger".cell_ref_put(v_root,3,'locals',i_locals_root);
    WITH j_ret AS (  
      INSERT INTO "gw_ledger"."ExecutionContext" (
        "context_root",
        "state_root",
        "origin",
        "address",
        "caller",
        "transaction_root",
        "block_height",
        "timestamp",
        "locals_root",
        "cost_used",
        "cost_limit",
        "depth"
      ) VALUES (
        (v_root)::BYTEA,
        (i_state_root)::BYTEA,
        (i_origin)::BYTEA,
        (i_address)::BYTEA,
        (i_caller)::BYTEA,
        (i_transaction_root)::BYTEA,
        (i_block_height)::BIGINT,
        (i_timestamp)::BIGINT,
        (i_locals_root)::BYTEA,
        (i_cost_used)::BIGINT,
        (i_cost_limit)::BIGINT,
        (i_depth)::INTEGER
      ) ON CONFLICT ("context_root") DO UPDATE SET ("context_root",
        "state_root",
        "origin",
        "address",
        "caller",
        "transaction_root",
        "block_height",
        "timestamp",
        "locals_root",
        "cost_used",
        "cost_limit",
        "depth") = row(
        EXCLUDED."context_root",
        EXCLUDED."state_root",
        EXCLUDED."origin",
        EXCLUDED."address",
        EXCLUDED."caller",
        EXCLUDED."transaction_root",
        EXCLUDED."block_height",
        EXCLUDED."timestamp",
        EXCLUDED."locals_root",
        EXCLUDED."cost_used",
        EXCLUDED."cost_limit",
        EXCLUDED."depth"
      ) RETURNING
        "context_root",
        "state_root",
        "origin",
        "address",
        "caller",
        "transaction_root",
        "block_height",
        "timestamp",
        "locals_root",
        "cost_used",
        "cost_limit",
        "depth")
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN v_root;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.context/context-get [101] 
CREATE OR REPLACE FUNCTION "gw_ledger".context_get(
  i_context_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT
        "context_root",
        "state_root",
        "origin",
        "address",
        "caller",
        "transaction_root",
        "block_height",
        "timestamp",
        "locals_root",
        "cost_used",
        "cost_limit",
        "depth"
      FROM "gw_ledger"."ExecutionContext"
      WHERE "context_root" = i_context_root
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.context/context-can-charge [108] 
CREATE OR REPLACE FUNCTION "gw_ledger".context_can_charge(
  i_context_root BYTEA,
  i_cost BIGINT
) RETURNS BOOLEAN AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    o_row := "gw_ledger".context_get(i_context_root);
    RETURN o_row IS NOT NULL AND (i_cost >= 0) AND (((o_row ->> 'cost_used')::BIGINT + i_cost) <= (o_row ->> 'cost_limit')::BIGINT);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.context/context-charge [118] 
CREATE OR REPLACE FUNCTION "gw_ledger".context_charge(
  i_context_root BYTEA,
  i_cost BIGINT
) RETURNS BYTEA AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    o_row := "gw_ledger".context_get(i_context_root);
    IF NOT (o_row IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_context','data',null))::TEXT,
        MESSAGE = 'ledger/missing-context'
      ;
    END IF;
    IF NOT ("gw_ledger".context_can_charge(i_context_root,i_cost)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/cost_limit','data',null))::TEXT,
        MESSAGE = 'ledger/cost-limit'
      ;
    END IF;
    RETURN "gw_ledger".context_create(
      (o_row ->> 'state_root')::BYTEA,
      (o_row ->> 'origin')::BYTEA,
      (o_row ->> 'address')::BYTEA,
      (o_row ->> 'caller')::BYTEA,
      (o_row ->> 'transaction_root')::BYTEA,
      (o_row ->> 'block_height')::BIGINT,
      (o_row ->> 'timestamp')::BIGINT,
      (o_row ->> 'locals_root')::BYTEA,
      (o_row ->> 'cost_used')::BIGINT + i_cost,
      (o_row ->> 'cost_limit')::BIGINT,
      (o_row ->> 'depth')::INTEGER
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.context/context-with-state [140] 
CREATE OR REPLACE FUNCTION "gw_ledger".context_with_state(
  i_context_root BYTEA,
  i_state_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    o_row := "gw_ledger".context_get(i_context_root);
    IF NOT (o_row IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_context','data',null))::TEXT,
        MESSAGE = 'ledger/missing-context'
      ;
    END IF;
    RETURN "gw_ledger".context_create(
      i_state_root,
      (o_row ->> 'origin')::BYTEA,
      (o_row ->> 'address')::BYTEA,
      (o_row ->> 'caller')::BYTEA,
      (o_row ->> 'transaction_root')::BYTEA,
      (o_row ->> 'block_height')::BIGINT,
      (o_row ->> 'timestamp')::BIGINT,
      (o_row ->> 'locals_root')::BYTEA,
      (o_row ->> 'cost_used')::BIGINT,
      (o_row ->> 'cost_limit')::BIGINT,
      (o_row ->> 'depth')::INTEGER
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.context/context-with-locals [160] 
CREATE OR REPLACE FUNCTION "gw_ledger".context_with_locals(
  i_context_root BYTEA,
  i_locals_root BYTEA,
  i_depth INTEGER
) RETURNS BYTEA AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    o_row := "gw_ledger".context_get(i_context_root);
    RETURN "gw_ledger".context_create(
      (o_row ->> 'state_root')::BYTEA,
      (o_row ->> 'origin')::BYTEA,
      (o_row ->> 'address')::BYTEA,
      (o_row ->> 'caller')::BYTEA,
      (o_row ->> 'transaction_root')::BYTEA,
      (o_row ->> 'block_height')::BIGINT,
      (o_row ->> 'timestamp')::BIGINT,
      i_locals_root,
      (o_row ->> 'cost_used')::BIGINT,
      (o_row ->> 'cost_limit')::BIGINT,
      i_depth
    );
  END;

$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- gwdb.ledger.function/Function [16] 
DROP TABLE IF EXISTS "gw_ledger"."Function" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."Function" (
  "function_root" BYTEA PRIMARY KEY,
  "function_version" SMALLINT NOT NULL,
  "parameters_root" BYTEA NOT NULL,
  "body_root" BYTEA NOT NULL,
  "closure_root" BYTEA NOT NULL,
  "metadata_root" BYTEA NOT NULL
);

-- gwdb.ledger.function/function-payload [26] 
CREATE OR REPLACE FUNCTION "gw_ledger".function_payload(
  i_parameters_root BYTEA,
  i_body_root BYTEA,
  i_closure_root BYTEA,
  i_metadata_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN decode(
    'R:function:1:4:' || encode(i_parameters_root,'hex') || encode(i_body_root,'hex') || encode(i_closure_root,'hex') || encode(i_metadata_root,'hex'),
    'escape'
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.function/function-put [41] 
CREATE OR REPLACE FUNCTION "gw_ledger".function_put(
  i_parameters_root BYTEA,
  i_body_root BYTEA,
  i_closure_root BYTEA,
  i_metadata_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_body JSONB;
    o_body_ref JSONB;
    o_closure JSONB;
    o_closure_ref JSONB;
    o_metadata JSONB;
    o_metadata_ref JSONB;
    o_parameters JSONB;
    o_parameters_ref JSONB;
    o_upsert JSONB;
    v_payload BYTEA;
    v_root BYTEA;
  BEGIN
    o_parameters := "gw_ledger".cell_by_hash(i_parameters_root);
    o_body := "gw_ledger".cell_by_hash(i_body_root);
    o_closure := "gw_ledger".cell_by_hash(i_closure_root);
    o_metadata := "gw_ledger".cell_by_hash(i_metadata_root);
    IF NOT (o_parameters IS NOT NULL AND ((o_parameters ->> 'type_tag')::SMALLINT = 10)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/function_parameters_not_vector',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/function-parameters-not-vector'
      ;
    END IF;
    IF NOT (o_body IS NOT NULL AND ((o_body ->> 'type_tag')::SMALLINT = 17)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/function_body_not_operation',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/function-body-not-operation'
      ;
    END IF;
    IF NOT (o_closure IS NOT NULL AND ((o_closure ->> 'type_tag')::SMALLINT = 10)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/function_closure_not_vector',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/function-closure-not-vector'
      ;
    END IF;
    IF NOT (o_metadata IS NOT NULL AND ((o_metadata ->> 'type_tag')::SMALLINT = 11)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/function_metadata_not_map',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/function-metadata-not-map'
      ;
    END IF;
    v_payload := "gw_ledger".function_payload(i_parameters_root,i_body_root,i_closure_root,i_metadata_root);
    v_root := "gw_ledger".cell_put("gw_ledger".canonical_hash(18,v_payload),1,18,v_payload);
    o_parameters_ref := "gw_ledger".cell_ref_put(v_root,0,'parameters',i_parameters_root);
    o_body_ref := "gw_ledger".cell_ref_put(v_root,1,'body',i_body_root);
    o_closure_ref := "gw_ledger".cell_ref_put(v_root,2,'closure',i_closure_root);
    o_metadata_ref := "gw_ledger".cell_ref_put(v_root,3,'metadata',i_metadata_root);
    WITH j_ret AS (  
      INSERT INTO "gw_ledger"."Function" (
        "function_root",
        "function_version",
        "parameters_root",
        "body_root",
        "closure_root",
        "metadata_root"
      ) VALUES (
        (v_root)::BYTEA,
        (1)::SMALLINT,
        (i_parameters_root)::BYTEA,
        (i_body_root)::BYTEA,
        (i_closure_root)::BYTEA,
        (i_metadata_root)::BYTEA
      ) ON CONFLICT ("function_root") DO UPDATE SET ("function_root",
        "function_version",
        "parameters_root",
        "body_root",
        "closure_root",
        "metadata_root") = row(
        EXCLUDED."function_root",
        EXCLUDED."function_version",
        EXCLUDED."parameters_root",
        EXCLUDED."body_root",
        EXCLUDED."closure_root",
        EXCLUDED."metadata_root"
      ) RETURNING
        "function_root",
        "function_version",
        "parameters_root",
        "body_root",
        "closure_root",
        "metadata_root")
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_upsert;
    RETURN v_root;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.function/function-get [80] 
CREATE OR REPLACE FUNCTION "gw_ledger".function_get(
  i_function_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT
        "function_root",
        "function_version",
        "parameters_root",
        "body_root",
        "closure_root",
        "metadata_root"
      FROM "gw_ledger"."Function"
      WHERE "function_root" = i_function_root
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.function/function-valid [87] 
CREATE OR REPLACE FUNCTION "gw_ledger".function_valid(
  i_function_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_cell JSONB;
    o_function JSONB;
    v_payload BYTEA;
  BEGIN
    o_cell := "gw_ledger".cell_by_hash(i_function_root);
    o_function := "gw_ledger".function_get(i_function_root);
    IF o_cell IS NULL OR o_function IS NULL THEN
      RETURN false;
    END IF;
    v_payload := "gw_ledger".function_payload(
      (o_function ->> 'parameters_root')::BYTEA,
      (o_function ->> 'body_root')::BYTEA,
      (o_function ->> 'closure_root')::BYTEA,
      (o_function ->> 'metadata_root')::BYTEA
    );
    RETURN ((o_cell ->> 'type_tag')::SMALLINT = 18) AND ((o_cell ->> 'payload')::BYTEA = v_payload) AND "gw_ledger".verify(i_function_root,18,v_payload) AND ("gw_ledger".cell_ref_count(i_function_root,'parameters') = 1) AND ("gw_ledger".cell_ref_count(i_function_root,'body') = 1) AND ("gw_ledger".cell_ref_count(i_function_root,'closure') = 1) AND ("gw_ledger".cell_ref_count(i_function_root,'metadata') = 1);
  END;

$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- gwdb.ledger.op/Op [18] 
DROP TABLE IF EXISTS "gw_ledger"."Op" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."Op" (
  "op_root" BYTEA PRIMARY KEY,
  "op_kind" TEXT NOT NULL,
  "value_root" BYTEA,
  "symbol_root" BYTEA,
  "local_depth" INTEGER,
  "local_index" INTEGER,
  "function_root" BYTEA,
  "parameter_root" BYTEA,
  "body_root" BYTEA
);

-- gwdb.ledger.op/OpChild [31] 
DROP TABLE IF EXISTS "gw_ledger"."OpChild" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."OpChild" (
  "op_root" BYTEA,
  "position" INTEGER,
  "child_root" BYTEA NOT NULL,
  PRIMARY KEY (op_root,position)
);

-- gwdb.ledger.op/op-kind-valid [38] 
CREATE OR REPLACE FUNCTION "gw_ledger".op_kind_valid(
  i_op_kind TEXT
) RETURNS BOOLEAN AS $$

  SELECT (i_op_kind = 'constant') OR (i_op_kind = 'local') OR (i_op_kind = 'lookup') OR (i_op_kind = 'invoke') OR (i_op_kind = 'lambda') OR (i_op_kind = 'do') OR (i_op_kind = 'cond') OR (i_op_kind = 'let') OR (i_op_kind = 'def') OR (i_op_kind = 'special');

$$ LANGUAGE 'sql' IMMUTABLE PARALLEL SAFE;

-- gwdb.ledger.op/op-root-hex [56] 
CREATE OR REPLACE FUNCTION "gw_ledger".op_root_hex(
  i_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN CASE WHEN i_root IS NULL THEN '-'
  ELSE encode(i_root,'hex')
  END;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.op/op-payload [64] 
CREATE OR REPLACE FUNCTION "gw_ledger".op_payload(
  i_op_kind TEXT,
  i_value_root BYTEA,
  i_symbol_root BYTEA,
  i_local_depth INTEGER,
  i_local_index INTEGER,
  i_function_root BYTEA,
  i_parameter_root BYTEA,
  i_body_root BYTEA,
  i_child_roots JSONB
) RETURNS BYTEA AS $$

  DECLARE
    v_child_count INTEGER;
    v_children BYTEA;
    v_prefix TEXT;
  BEGIN
    v_child_count := jsonb_array_length(i_child_roots);
    IF NOT (v_child_count IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/op_children_must_be_array',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/op-children-must-be-array'
      ;
    END IF;
    v_prefix := ('O:1:' || i_op_kind || ':' || "gw_ledger".op_root_hex(i_value_root) || ':' || "gw_ledger".op_root_hex(i_symbol_root) || ':' || CASE WHEN i_local_depth IS NULL THEN '-'
    ELSE (i_local_depth)::TEXT
    END || ':' || CASE WHEN i_local_index IS NULL THEN '-'
    ELSE (i_local_index)::TEXT
    END || ':' || "gw_ledger".op_root_hex(i_function_root) || ':' || "gw_ledger".op_root_hex(i_parameter_root) || ':' || "gw_ledger".op_root_hex(i_body_root) || ':');
    v_children := "gw_ledger".sequence_payload(i_child_roots);
    RETURN decode(v_prefix,'escape') || v_children;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.op/op-children-put [95] 
CREATE OR REPLACE FUNCTION "gw_ledger".op_children_put(
  i_op_root BYTEA,
  i_child_roots JSONB,
  i_position INTEGER,
  i_count INTEGER
) RETURNS JSONB AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN null;
  ELSE
    DECLARE
    o_next JSONB;
      o_ref JSONB;
      o_row JSONB;
      v_child_root BYTEA;
  BEGIN
    v_child_root := "gw_ledger".child_root_at(i_child_roots,i_position);
      o_ref := "gw_ledger".cell_ref_put(i_op_root,i_position,'op-child',v_child_root);
      WITH j_ret AS (  
        INSERT INTO "gw_ledger"."OpChild" ("op_root","position","child_root") VALUES (
          (i_op_root)::BYTEA,
          (i_position)::INTEGER,
          (v_child_root)::BYTEA
        ) ON CONFLICT ("op_root","position") DO UPDATE SET ("op_root","position","child_root") = row(EXCLUDED."op_root",EXCLUDED."position",EXCLUDED."child_root") RETURNING "op_root","position","child_root")
      SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
      o_next := "gw_ledger".op_children_put(i_op_root,i_child_roots,i_position + 1,i_count);
      RETURN o_row;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.op/put-op [111] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_op(
  i_op_kind TEXT,
  i_value_root BYTEA,
  i_symbol_root BYTEA,
  i_local_depth INTEGER,
  i_local_index INTEGER,
  i_function_root BYTEA,
  i_parameter_root BYTEA,
  i_body_root BYTEA,
  i_child_roots JSONB
) RETURNS BYTEA AS $$

  DECLARE
    o_children JSONB;
    o_upsert JSONB;
    v_count INTEGER;
    v_payload BYTEA;
    v_root BYTEA;
  BEGIN
    IF NOT ("gw_ledger".op_kind_valid(i_op_kind)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/unknown_op','data',i_op_kind))::TEXT,
        MESSAGE = 'ledger/unknown-op'
      ;
    END IF;
    v_count := jsonb_array_length(i_child_roots);
    v_payload := "gw_ledger".op_payload(
      i_op_kind,
      i_value_root,
      i_symbol_root,
      i_local_depth,
      i_local_index,
      i_function_root,
      i_parameter_root,
      i_body_root,
      i_child_roots
    );
    v_root := "gw_ledger".cell_put("gw_ledger".canonical_hash(17,v_payload),1,17,v_payload);
    WITH j_ret AS (  
      INSERT INTO "gw_ledger"."Op" (
        "op_root",
        "op_kind",
        "value_root",
        "symbol_root",
        "local_depth",
        "local_index",
        "function_root",
        "parameter_root",
        "body_root"
      ) VALUES (
        (v_root)::BYTEA,
        (i_op_kind)::TEXT,
        (i_value_root)::BYTEA,
        (i_symbol_root)::BYTEA,
        (i_local_depth)::INTEGER,
        (i_local_index)::INTEGER,
        (i_function_root)::BYTEA,
        (i_parameter_root)::BYTEA,
        (i_body_root)::BYTEA
      ) ON CONFLICT ("op_root") DO UPDATE SET ("op_root",
        "op_kind",
        "value_root",
        "symbol_root",
        "local_depth",
        "local_index",
        "function_root",
        "parameter_root",
        "body_root") = row(
        EXCLUDED."op_root",
        EXCLUDED."op_kind",
        EXCLUDED."value_root",
        EXCLUDED."symbol_root",
        EXCLUDED."local_depth",
        EXCLUDED."local_index",
        EXCLUDED."function_root",
        EXCLUDED."parameter_root",
        EXCLUDED."body_root"
      ) RETURNING
        "op_root",
        "op_kind",
        "value_root",
        "symbol_root",
        "local_depth",
        "local_index",
        "function_root",
        "parameter_root",
        "body_root")
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_upsert;
    o_children := "gw_ledger".op_children_put(v_root,i_child_roots,0,v_count);
    RETURN v_root;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.op/constant [147] 
CREATE OR REPLACE FUNCTION "gw_ledger".constant(
  i_value_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_op(
    'constant',
    i_value_root,
    null,
    null,
    null,
    null,
    null,
    null,
    jsonb_build_array()
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.op/local [153] 
CREATE OR REPLACE FUNCTION "gw_ledger".local(
  i_depth INTEGER,
  i_index INTEGER
) RETURNS BYTEA AS $$

  BEGIN
    IF NOT ((i_depth >= 0) AND (i_index >= 0)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_local_address',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-local-address'
      ;
    END IF;
    RETURN "gw_ledger".put_op(
      'local',
      null,
      null,
      i_depth,
      i_index,
      null,
      null,
      null,
      jsonb_build_array()
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.op/lookup [161] 
CREATE OR REPLACE FUNCTION "gw_ledger".lookup(
  i_symbol_root BYTEA
) RETURNS BYTEA AS $$

  BEGIN
    IF NOT ("gw_ledger".cell_type_tag(i_symbol_root) = 7) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/lookup_requires_symbol',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/lookup-requires-symbol'
      ;
    END IF;
    RETURN "gw_ledger".put_op(
      'lookup',
      null,
      i_symbol_root,
      null,
      null,
      null,
      null,
      null,
      jsonb_build_array()
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.op/invoke [169] 
CREATE OR REPLACE FUNCTION "gw_ledger".invoke(
  i_function_root BYTEA,
  i_argument_roots JSONB
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_op(
    'invoke',
    null,
    null,
    null,
    null,
    i_function_root,
    null,
    null,
    i_argument_roots
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.op/do-op [175] 
CREATE OR REPLACE FUNCTION "gw_ledger".do_op(
  i_child_roots JSONB
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_op('do',null,null,null,null,null,null,null,i_child_roots);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.op/cond-op [180] 
CREATE OR REPLACE FUNCTION "gw_ledger".cond_op(
  i_child_roots JSONB
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_op('cond',null,null,null,null,null,null,null,i_child_roots);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.op/def-op [186] 
CREATE OR REPLACE FUNCTION "gw_ledger".def_op(
  i_symbol_root BYTEA,
  i_value_op_root BYTEA
) RETURNS BYTEA AS $$

  BEGIN
    IF NOT ("gw_ledger".cell_type_tag(i_symbol_root) = 7) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/def_requires_symbol','data',null))::TEXT,
        MESSAGE = 'ledger/def-requires-symbol'
      ;
    END IF;
    RETURN "gw_ledger".put_op(
      'def',
      null,
      i_symbol_root,
      null,
      null,
      null,
      null,
      null,
      jsonb_build_array(encode(i_value_op_root,'hex'))
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.op/let-op [196] 
CREATE OR REPLACE FUNCTION "gw_ledger".let_op(
  i_symbol_root BYTEA,
  i_binding_op_root BYTEA,
  i_body_op_root BYTEA
) RETURNS BYTEA AS $$

  BEGIN
    IF NOT ("gw_ledger".cell_type_tag(i_symbol_root) = 7) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/let_requires_symbol','data',null))::TEXT,
        MESSAGE = 'ledger/let-requires-symbol'
      ;
    END IF;
    RETURN "gw_ledger".put_op(
      'let',
      null,
      i_symbol_root,
      null,
      null,
      null,
      null,
      null,
      jsonb_build_array(encode(i_binding_op_root,'hex'),encode(i_body_op_root,'hex'))
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.op/lambda-op [207] 
CREATE OR REPLACE FUNCTION "gw_ledger".lambda_op(
  i_parameters_root BYTEA,
  i_body_op_root BYTEA
) RETURNS BYTEA AS $$

  BEGIN
    IF NOT ("gw_ledger".cell_type_tag(i_parameters_root) = 10) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/lambda_parameters_not_vector',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/lambda-parameters-not-vector'
      ;
    END IF;
    IF NOT ("gw_ledger".cell_type_tag(i_body_op_root) = 17) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/lambda_body_not_operation',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/lambda-body-not-operation'
      ;
    END IF;
    RETURN "gw_ledger".put_op(
      'lambda',
      null,
      null,
      null,
      null,
      null,
      i_parameters_root,
      i_body_op_root,
      jsonb_build_array()
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.op/op-get [218] 
CREATE OR REPLACE FUNCTION "gw_ledger".op_get(
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT
        "op_root",
        "op_kind",
        "value_root",
        "symbol_root",
        "local_depth",
        "local_index",
        "function_root",
        "parameter_root",
        "body_root"
      FROM "gw_ledger"."Op"
      WHERE "op_root" = i_op_root
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.op/op-child-root [225] 
CREATE OR REPLACE FUNCTION "gw_ledger".op_child_root(
  i_op_root BYTEA,
  i_position INTEGER
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_ref_child(i_op_root,i_position,'op-child');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.op/op-child-roots [231] 
CREATE OR REPLACE FUNCTION "gw_ledger".op_child_roots(
  i_op_root BYTEA,
  i_position INTEGER,
  i_count INTEGER,
  i_out JSONB
) RETURNS JSONB AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN i_out;
  ELSE
    DECLARE
    v_child_root BYTEA;
      v_next JSONB;
  BEGIN
    v_child_root := "gw_ledger".op_child_root(i_op_root,i_position);
      v_next := (i_out || jsonb_build_array(encode(v_child_root,'hex')));
      RETURN "gw_ledger".op_child_roots(i_op_root,i_position + 1,i_count,v_next);
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.op/op-valid [244] 
CREATE OR REPLACE FUNCTION "gw_ledger".op_valid(
  i_op_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_cell JSONB;
    o_op JSONB;
    v_children JSONB;
    v_count INTEGER;
    v_payload BYTEA;
    v_valid BOOLEAN;
  BEGIN
    o_cell := "gw_ledger".cell_by_hash(i_op_root);
    o_op := "gw_ledger".op_get(i_op_root);
    IF o_cell IS NULL OR o_op IS NULL THEN
      RETURN false;
    END IF;
    v_count := "gw_ledger".cell_ref_count(i_op_root,'op-child');
    v_children := "gw_ledger".op_child_roots(i_op_root,0,v_count,jsonb_build_array());
    v_payload := "gw_ledger".op_payload(
      (o_op ->> 'op_kind')::TEXT,
      (o_op ->> 'value_root')::BYTEA,
      (o_op ->> 'symbol_root')::BYTEA,
      (o_op ->> 'local_depth')::INTEGER,
      (o_op ->> 'local_index')::INTEGER,
      (o_op ->> 'function_root')::BYTEA,
      (o_op ->> 'parameter_root')::BYTEA,
      (o_op ->> 'body_root')::BYTEA,
      v_children
    );
    v_valid := (((o_cell ->> 'type_tag')::SMALLINT = 17) AND "gw_ledger".op_kind_valid((o_op ->> 'op_kind')::TEXT) AND ((o_cell ->> 'payload')::BYTEA = v_payload) AND "gw_ledger".verify(i_op_root,17,v_payload));
    RETURN v_valid;
  END;

$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- gwdb.ledger.primitive/Primitive [16] 
DROP TABLE IF EXISTS "gw_ledger"."Primitive" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."Primitive" (
  "primitive_root" BYTEA PRIMARY KEY,
  "primitive_id" TEXT NOT NULL,
  "arity" INTEGER NOT NULL,
  UNIQUE ("primitive_id")
);

-- gwdb.ledger.primitive/primitive-id-valid [23] 
CREATE OR REPLACE FUNCTION "gw_ledger".primitive_id_valid(
  i_primitive_id TEXT,
  i_arity INTEGER
) RETURNS BOOLEAN AS $$

  SELECT ((i_primitive_id = 'integer/add') AND (i_arity = 2)) OR ((i_primitive_id = 'integer/multiply') AND (i_arity = 2));

$$ LANGUAGE 'sql' IMMUTABLE PARALLEL SAFE;

-- gwdb.ledger.primitive/primitive-payload [33] 
CREATE OR REPLACE FUNCTION "gw_ledger".primitive_payload(
  i_primitive_id TEXT,
  i_arity INTEGER
) RETURNS BYTEA AS $$
BEGIN
  RETURN decode('P:1:' || i_primitive_id || ':' || i_arity,'escape');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.primitive/primitive-put [39] 
CREATE OR REPLACE FUNCTION "gw_ledger".primitive_put(
  i_primitive_id TEXT,
  i_arity INTEGER
) RETURNS BYTEA AS $$

  DECLARE
    o_upsert JSONB;
    v_payload BYTEA;
    v_root BYTEA;
  BEGIN
    IF NOT ("gw_ledger".primitive_id_valid(i_primitive_id,i_arity)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/unknown_primitive',
          'data',
          i_primitive_id
        ))::TEXT,
        MESSAGE = 'ledger/unknown-primitive'
      ;
    END IF;
    v_payload := "gw_ledger".primitive_payload(i_primitive_id,i_arity);
    v_root := "gw_ledger".cell_put("gw_ledger".canonical_hash(16,v_payload),1,16,v_payload);
    WITH j_ret AS (  
      INSERT INTO "gw_ledger"."Primitive" ("primitive_root","primitive_id","arity") VALUES ((v_root)::BYTEA,(i_primitive_id)::TEXT,(i_arity)::INTEGER) ON CONFLICT ("primitive_root") DO UPDATE SET ("primitive_root","primitive_id","arity") = row(
        EXCLUDED."primitive_root",
        EXCLUDED."primitive_id",
        EXCLUDED."arity"
      ) RETURNING "primitive_root","primitive_id","arity")
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_upsert;
    RETURN v_root;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.primitive/primitive-get [54] 
CREATE OR REPLACE FUNCTION "gw_ledger".primitive_get(
  i_primitive_id TEXT
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT "primitive_root","primitive_id","arity" FROM "gw_ledger"."Primitive"
      WHERE "primitive_id" = i_primitive_id
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.primitive/primitive-get-root [61] 
CREATE OR REPLACE FUNCTION "gw_ledger".primitive_get_root(
  i_primitive_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT "primitive_root","primitive_id","arity" FROM "gw_ledger"."Primitive"
      WHERE "primitive_root" = i_primitive_root
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime/ExecutionResult [29] 
DROP TABLE IF EXISTS "gw_ledger"."ExecutionResult" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."ExecutionResult" (
  "result_root" BYTEA PRIMARY KEY,
  "status" TEXT NOT NULL,
  "context_root" BYTEA NOT NULL,
  "value_root" BYTEA,
  "error_code" TEXT,
  "cost_used" BIGINT NOT NULL
);

-- gwdb.ledger.runtime/result-ok [39] 
CREATE OR REPLACE FUNCTION "gw_ledger".result_ok(
  i_context_root BYTEA,
  i_value_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_context JSONB;
  BEGIN
    o_context := "gw_ledger".context_get(i_context_root);
    RETURN jsonb_build_object(
      'status',
      'ok',
      'context_root',
      i_context_root,
      'value_root',
      i_value_root,
      'cost_used',
      (o_context ->> 'cost_used')::BIGINT
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime/result-error [49] 
CREATE OR REPLACE FUNCTION "gw_ledger".result_error(
  i_context_root BYTEA,
  i_error_code TEXT
) RETURNS JSONB AS $$

  DECLARE
    o_context JSONB;
    v_cost_used BIGINT;
  BEGIN
    o_context := "gw_ledger".context_get(i_context_root);
    v_cost_used := CASE WHEN o_context IS NULL THEN (0)::BIGINT
    ELSE (o_context ->> 'cost_used')::BIGINT
    END;
    RETURN jsonb_build_object(
      'status',
      'error',
      'context_root',
      i_context_root,
      'error',
      jsonb_build_object('code',i_error_code),
      'cost_used',
      v_cost_used
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime/execute-constant [62] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_constant(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_context JSONB;
    o_op JSONB;
  BEGIN
    o_context := "gw_ledger".context_get(i_context_root);
    o_op := "gw_ledger".op_get(i_op_root);
    IF o_context is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'missing-context');
    ELSIF NOT "gw_ledger".op_valid(i_op_root) THEN
      RETURN "gw_ledger".result_error(i_context_root,'invalid-op');
    ELSIF NOT ((o_op ->> 'op_kind')::TEXT = 'constant') THEN
      RETURN "gw_ledger".result_error(i_context_root,'wrong-op-kind');
    ELSIF NOT "gw_ledger".context_can_charge(i_context_root,1) THEN
      RETURN "gw_ledger".result_error(i_context_root,'cost-limit');
    ELSE
      DECLARE
      v_next_context BYTEA;
    BEGIN
      v_next_context := "gw_ledger".context_charge(i_context_root,1);
        RETURN "gw_ledger".result_ok(v_next_context,(o_op ->> 'value_root')::BYTEA);
    END;
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime/execute-special [80] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_special(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_context JSONB;
    o_op JSONB;
    o_symbol JSONB;
    v_special TEXT;
  BEGIN
    o_context := "gw_ledger".context_get(i_context_root);
    o_op := "gw_ledger".op_get(i_op_root);
    o_symbol := "gw_ledger".cell_by_hash((o_op ->> 'symbol_root')::BYTEA);
    v_special := encode((o_symbol ->> 'payload')::BYTEA,'escape');
    IF o_context is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'missing-context');
    ELSIF NOT "gw_ledger".op_valid(i_op_root) THEN
      RETURN "gw_ledger".result_error(i_context_root,'invalid-op');
    ELSIF NOT ((o_op ->> 'op_kind')::TEXT = 'special') THEN
      RETURN "gw_ledger".result_error(i_context_root,'wrong-op-kind');
    ELSIF NOT "gw_ledger".context_can_charge(i_context_root,1) THEN
      RETURN "gw_ledger".result_error(i_context_root,'cost-limit');
    ELSIF v_special = 'state-root' THEN
      RETURN "gw_ledger".result_ok(
        "gw_ledger".context_charge(i_context_root,1),
        (o_context ->> 'state_root')::BYTEA
      );
    ELSIF v_special = 'origin' THEN
      RETURN "gw_ledger".result_ok(
        "gw_ledger".context_charge(i_context_root,1),
        (o_context ->> 'origin')::BYTEA
      );
    ELSIF v_special = 'address' THEN
      RETURN "gw_ledger".result_ok(
        "gw_ledger".context_charge(i_context_root,1),
        (o_context ->> 'address')::BYTEA
      );
    ELSIF v_special = 'caller' THEN
      RETURN "gw_ledger".result_ok("gw_ledger".context_charge(i_context_root,1),CASE WHEN o_context ->> 'caller' IS NULL THEN "gw_ledger".put_nil()
    ELSE (o_context ->> 'caller')::BYTEA
    END);
    ELSIF v_special = 'transaction' THEN
      RETURN "gw_ledger".result_ok("gw_ledger".context_charge(i_context_root,1),CASE WHEN o_context ->> 'transaction_root' IS NULL THEN "gw_ledger".put_nil()
    ELSE (o_context ->> 'transaction_root')::BYTEA
    END);
    ELSIF v_special = 'block-height' THEN
      RETURN "gw_ledger".result_ok(
        "gw_ledger".context_charge(i_context_root,1),
        "gw_ledger".put_integer_number((o_context ->> 'block_height')::BIGINT)
      );
    ELSIF v_special = 'timestamp' THEN
      RETURN "gw_ledger".result_ok(
        "gw_ledger".context_charge(i_context_root,1),
        "gw_ledger".put_integer_number((o_context ->> 'timestamp')::BIGINT)
      );
    ELSIF v_special = 'depth' THEN
      RETURN "gw_ledger".result_ok(
        "gw_ledger".context_charge(i_context_root,1),
        "gw_ledger".put_integer_number((o_context ->> 'depth')::INTEGER)
      );
    ELSIF v_special = 'cost-used' THEN
      RETURN "gw_ledger".result_ok(
        "gw_ledger".context_charge(i_context_root,1),
        "gw_ledger".put_integer_number((o_context ->> 'cost_used')::BIGINT)
      );
    ELSIF v_special = 'cost-limit' THEN
      RETURN "gw_ledger".result_ok(
        "gw_ledger".context_charge(i_context_root,1),
        "gw_ledger".put_integer_number((o_context ->> 'cost_limit')::BIGINT)
      );
    ELSE
      RETURN "gw_ledger".result_error(i_context_root,'unknown-special');
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime/execute-lookup [144] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_lookup(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_context JSONB;
    o_op JSONB;
    v_account_root BYTEA;
    v_value_root BYTEA;
  BEGIN
    o_context := "gw_ledger".context_get(i_context_root);
    o_op := "gw_ledger".op_get(i_op_root);
    IF o_context is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'missing-context');
    END IF;
    IF NOT "gw_ledger".op_valid(i_op_root) THEN
      RETURN "gw_ledger".result_error(i_context_root,'invalid-op');
    END IF;
    IF NOT ((o_op ->> 'op_kind')::TEXT = 'lookup') THEN
      RETURN "gw_ledger".result_error(i_context_root,'wrong-op-kind');
    END IF;
    IF NOT "gw_ledger".context_can_charge(i_context_root,2) THEN
      RETURN "gw_ledger".result_error(i_context_root,'cost-limit');
    END IF;
    v_account_root := "gw_ledger".state_account_root(
      (o_context ->> 'state_root')::BYTEA,
      (o_context ->> 'address')::BYTEA
    );
    IF v_account_root is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'missing-account');
    END IF;
    v_value_root := "gw_ledger".account_value_lookup(v_account_root,(o_op ->> 'symbol_root')::BYTEA);
    IF v_value_root is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'unbound-symbol');
    ELSE
      RETURN "gw_ledger".result_ok("gw_ledger".context_charge(i_context_root,2),v_value_root);
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime/execute-local [172] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_local(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_context JSONB;
    o_op JSONB;
    v_depth INTEGER;
    v_index INTEGER;
    v_value_root BYTEA;
  BEGIN
    o_context := "gw_ledger".context_get(i_context_root);
    o_op := "gw_ledger".op_get(i_op_root);
    IF o_context is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'missing-context');
    END IF;
    IF NOT "gw_ledger".op_valid(i_op_root) THEN
      RETURN "gw_ledger".result_error(i_context_root,'invalid-op');
    END IF;
    IF NOT ((o_op ->> 'op_kind')::TEXT = 'local') THEN
      RETURN "gw_ledger".result_error(i_context_root,'wrong-op-kind');
    END IF;
    IF NOT "gw_ledger".context_can_charge(i_context_root,1) THEN
      RETURN "gw_ledger".result_error(i_context_root,'cost-limit');
    END IF;
    v_depth := (o_op ->> 'local_depth')::INTEGER;
    v_index := (o_op ->> 'local_index')::INTEGER;
    IF NOT (v_depth = 0) THEN
      RETURN "gw_ledger".result_error(i_context_root,'unsupported-local-depth');
    END IF;
    v_value_root := "gw_ledger".vector_get((o_context ->> 'locals_root')::BYTEA,v_index);
    IF v_value_root is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'missing-local');
    ELSE
      RETURN "gw_ledger".result_ok("gw_ledger".context_charge(i_context_root,1),v_value_root);
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime/execute-let [198] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_let(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_binding_op JSONB;
    o_binding_result JSONB;
    o_body_op JSONB;
    o_context JSONB;
    o_op JSONB;
    v_binding_op BYTEA;
    v_body_op BYTEA;
    v_frame BYTEA;
    v_frame_context BYTEA;
    v_let_context BYTEA;
  BEGIN
    o_context := "gw_ledger".context_get(i_context_root);
    o_op := "gw_ledger".op_get(i_op_root);
    IF o_context is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'missing-context');
    END IF;
    IF NOT "gw_ledger".op_valid(i_op_root) THEN
      RETURN "gw_ledger".result_error(i_context_root,'invalid-op');
    END IF;
    IF NOT ((o_op ->> 'op_kind')::TEXT = 'let') THEN
      RETURN "gw_ledger".result_error(i_context_root,'wrong-op-kind');
    END IF;
    IF NOT "gw_ledger".context_can_charge(i_context_root,3) THEN
      RETURN "gw_ledger".result_error(i_context_root,'cost-limit');
    END IF;
    v_binding_op := "gw_ledger".op_child_root(i_op_root,0);
    v_body_op := "gw_ledger".op_child_root(i_op_root,1);
    o_binding_op := "gw_ledger".op_get(v_binding_op);
    o_body_op := "gw_ledger".op_get(v_body_op);
    IF o_binding_op IS NULL OR NOT ((o_binding_op ->> 'op_kind')::TEXT = 'constant') THEN
      RETURN "gw_ledger".result_error(i_context_root,'unsupported-let-binding');
    END IF;
    o_binding_result := "gw_ledger".execute_constant(i_context_root,v_binding_op);
    IF (o_binding_result ->> 'status')::TEXT = 'error' THEN
      RETURN o_binding_result;
    END IF;
    v_frame := "gw_ledger".put_vector(
      jsonb_build_array(encode((o_binding_result ->> 'value_root')::BYTEA,'hex'))
    );
    v_frame_context := "gw_ledger".context_with_locals(
      (o_binding_result ->> 'context_root')::BYTEA,
      v_frame,
      (o_context ->> 'depth')::INTEGER + 1
    );
    v_let_context := "gw_ledger".context_charge(v_frame_context,1);
    IF o_body_op is null  THEN
      RETURN "gw_ledger".result_error(v_let_context,'missing-let-body');
    ELSIF (o_body_op ->> 'op_kind')::TEXT = 'local' THEN
      RETURN "gw_ledger".execute_local(v_let_context,v_body_op);
    ELSIF (o_body_op ->> 'op_kind')::TEXT = 'constant' THEN
      RETURN "gw_ledger".execute_constant(v_let_context,v_body_op);
    ELSE
      RETURN "gw_ledger".result_error(v_let_context,'unsupported-let-body');
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime/execute-lambda [240] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_lambda(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_context JSONB;
    o_op JSONB;
    v_function_root BYTEA;
    v_metadata BYTEA;
    v_next_context BYTEA;
  BEGIN
    o_context := "gw_ledger".context_get(i_context_root);
    o_op := "gw_ledger".op_get(i_op_root);
    IF o_context is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'missing-context');
    END IF;
    IF NOT "gw_ledger".op_valid(i_op_root) THEN
      RETURN "gw_ledger".result_error(i_context_root,'invalid-op');
    END IF;
    IF NOT ((o_op ->> 'op_kind')::TEXT = 'lambda') THEN
      RETURN "gw_ledger".result_error(i_context_root,'wrong-op-kind');
    END IF;
    IF NOT "gw_ledger".context_can_charge(i_context_root,2) THEN
      RETURN "gw_ledger".result_error(i_context_root,'cost-limit');
    END IF;
    v_metadata := "gw_ledger".put_map(jsonb_build_array());
    v_function_root := "gw_ledger".function_put(
      (o_op ->> 'parameter_root')::BYTEA,
      (o_op ->> 'body_root')::BYTEA,
      (o_context ->> 'locals_root')::BYTEA,
      v_metadata
    );
    v_next_context := "gw_ledger".context_charge(i_context_root,2);
    RETURN "gw_ledger".result_ok(v_next_context,v_function_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime/execute-operand [264] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_operand(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_op JSONB;
  BEGIN
    o_op := "gw_ledger".op_get(i_op_root);
    IF o_op is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'invalid-operand');
    ELSIF (o_op ->> 'op_kind')::TEXT = 'constant' THEN
      RETURN "gw_ledger".execute_constant(i_context_root,i_op_root);
    ELSIF (o_op ->> 'op_kind')::TEXT = 'local' THEN
      RETURN "gw_ledger".execute_local(i_context_root,i_op_root);
    ELSE
      RETURN "gw_ledger".result_error(i_context_root,'unsupported-operand');
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime/execute-integer-add [278] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_integer_add(
  i_context_root BYTEA,
  i_left_op BYTEA,
  i_right_op BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_left_cell JSONB;
    o_left_result JSONB;
    o_right_cell JSONB;
    o_right_result JSONB;
    v_left BIGINT;
    v_next_context BYTEA;
    v_right BIGINT;
    v_value BYTEA;
  BEGIN
    IF NOT "gw_ledger".context_can_charge(i_context_root,4) THEN
      RETURN "gw_ledger".result_error(i_context_root,'cost-limit');
    END IF;
    o_left_result := "gw_ledger".execute_operand(i_context_root,i_left_op);
    IF (o_left_result ->> 'status')::TEXT = 'error' THEN
      RETURN o_left_result;
    END IF;
    o_right_result := "gw_ledger".execute_operand((o_left_result ->> 'context_root')::BYTEA,i_right_op);
    IF (o_right_result ->> 'status')::TEXT = 'error' THEN
      RETURN o_right_result;
    END IF;
    o_left_cell := "gw_ledger".cell_by_hash((o_left_result ->> 'value_root')::BYTEA);
    o_right_cell := "gw_ledger".cell_by_hash((o_right_result ->> 'value_root')::BYTEA);
    IF NOT (((o_left_cell ->> 'type_tag')::SMALLINT = 2) AND ((o_right_cell ->> 'type_tag')::SMALLINT = 2)) THEN
      RETURN "gw_ledger".result_error(i_context_root,'integer-required');
    END IF;
    v_left := (encode((o_left_cell ->> 'payload')::BYTEA,'escape'))::BIGINT;
    v_right := (encode((o_right_cell ->> 'payload')::BYTEA,'escape'))::BIGINT;
    v_value := "gw_ledger".put_integer_number(v_left + v_right);
    v_next_context := "gw_ledger".context_charge((o_right_result ->> 'context_root')::BYTEA,2);
    RETURN "gw_ledger".result_ok(v_next_context,v_value);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime/execute-integer-multiply [304] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_integer_multiply(
  i_context_root BYTEA,
  i_left_op BYTEA,
  i_right_op BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_left_cell JSONB;
    o_left_result JSONB;
    o_right_cell JSONB;
    o_right_result JSONB;
    v_left BIGINT;
    v_next_context BYTEA;
    v_right BIGINT;
    v_value BYTEA;
  BEGIN
    IF NOT "gw_ledger".context_can_charge(i_context_root,4) THEN
      RETURN "gw_ledger".result_error(i_context_root,'cost-limit');
    END IF;
    o_left_result := "gw_ledger".execute_operand(i_context_root,i_left_op);
    IF (o_left_result ->> 'status')::TEXT = 'error' THEN
      RETURN o_left_result;
    END IF;
    o_right_result := "gw_ledger".execute_operand((o_left_result ->> 'context_root')::BYTEA,i_right_op);
    IF (o_right_result ->> 'status')::TEXT = 'error' THEN
      RETURN o_right_result;
    END IF;
    o_left_cell := "gw_ledger".cell_by_hash((o_left_result ->> 'value_root')::BYTEA);
    o_right_cell := "gw_ledger".cell_by_hash((o_right_result ->> 'value_root')::BYTEA);
    IF NOT (((o_left_cell ->> 'type_tag')::SMALLINT = 2) AND ((o_right_cell ->> 'type_tag')::SMALLINT = 2)) THEN
      RETURN "gw_ledger".result_error(i_context_root,'integer-required');
    END IF;
    v_left := (encode((o_left_cell ->> 'payload')::BYTEA,'escape'))::BIGINT;
    v_right := (encode((o_right_cell ->> 'payload')::BYTEA,'escape'))::BIGINT;
    v_value := "gw_ledger".put_integer_number(v_left * v_right);
    v_next_context := "gw_ledger".context_charge((o_right_result ->> 'context_root')::BYTEA,2);
    RETURN "gw_ledger".result_ok(v_next_context,v_value);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime/execute-function-invoke-zero [330] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_function_invoke_zero(
  i_context_root BYTEA,
  i_op_root BYTEA,
  i_function_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_body JSONB;
    o_body_result JSONB;
    o_function JSONB;
    v_argument_count INTEGER;
    v_body_root BYTEA;
    v_next_context BYTEA;
    v_parameter_count INTEGER;
  BEGIN
    o_function := "gw_ledger".function_get(i_function_root);
    IF o_function is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'unknown-function');
    END IF;
    IF NOT "gw_ledger".function_valid(i_function_root) THEN
      RETURN "gw_ledger".result_error(i_context_root,'invalid-function');
    END IF;
    v_parameter_count := "gw_ledger".cell_ref_count((o_function ->> 'parameters_root')::BYTEA,'element');
    v_argument_count := "gw_ledger".cell_ref_count(i_op_root,'op-child');
    IF NOT ((v_parameter_count = 0) AND (v_argument_count = 0)) THEN
      RETURN "gw_ledger".result_error(i_context_root,'arity');
    END IF;
    IF NOT "gw_ledger".context_can_charge(i_context_root,3) THEN
      RETURN "gw_ledger".result_error(i_context_root,'cost-limit');
    END IF;
    v_body_root := (o_function ->> 'body_root')::BYTEA;
    o_body := "gw_ledger".op_get(v_body_root);
    IF o_body is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'missing-function-body');
    END IF;
    IF NOT ((o_body ->> 'op_kind')::TEXT = 'constant') THEN
      RETURN "gw_ledger".result_error(i_context_root,'unsupported-function-body');
    END IF;
    o_body_result := "gw_ledger".execute_constant(i_context_root,v_body_root);
    IF (o_body_result ->> 'status')::TEXT = 'error' THEN
      RETURN o_body_result;
    END IF;
    v_next_context := "gw_ledger".context_charge((o_body_result ->> 'context_root')::BYTEA,2);
    RETURN "gw_ledger".result_ok(v_next_context,(o_body_result ->> 'value_root')::BYTEA);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime/execute-function-invoke-one [361] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_function_invoke_one(
  i_context_root BYTEA,
  i_op_root BYTEA,
  i_function_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_argument_result JSONB;
    o_body JSONB;
    o_body_primitive JSONB;
    o_function JSONB;
    v_argument_count INTEGER;
    v_argument_op BYTEA;
    v_body_root BYTEA;
    v_call_context BYTEA;
    v_frame BYTEA;
    v_function_context BYTEA;
    v_parameter_count INTEGER;
  BEGIN
    o_function := "gw_ledger".function_get(i_function_root);
    IF o_function is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'unknown-function');
    END IF;
    IF NOT "gw_ledger".function_valid(i_function_root) THEN
      RETURN "gw_ledger".result_error(i_context_root,'invalid-function');
    END IF;
    v_parameter_count := "gw_ledger".cell_ref_count((o_function ->> 'parameters_root')::BYTEA,'element');
    v_argument_count := "gw_ledger".cell_ref_count(i_op_root,'op-child');
    IF NOT ((v_parameter_count = 1) AND (v_argument_count = 1)) THEN
      RETURN "gw_ledger".result_error(i_context_root,'arity');
    END IF;
    IF NOT "gw_ledger".context_can_charge(i_context_root,7) THEN
      RETURN "gw_ledger".result_error(i_context_root,'cost-limit');
    END IF;
    v_argument_op := "gw_ledger".op_child_root(i_op_root,0);
    o_argument_result := "gw_ledger".execute_operand(i_context_root,v_argument_op);
    IF (o_argument_result ->> 'status')::TEXT = 'error' THEN
      RETURN o_argument_result;
    END IF;
    v_frame := "gw_ledger".put_vector(
      jsonb_build_array(encode((o_argument_result ->> 'value_root')::BYTEA,'hex'))
    );
    v_function_context := "gw_ledger".context_with_locals((o_argument_result ->> 'context_root')::BYTEA,v_frame,1);
    v_call_context := "gw_ledger".context_charge(v_function_context,2);
    v_body_root := (o_function ->> 'body_root')::BYTEA;
    o_body := "gw_ledger".op_get(v_body_root);
    o_body_primitive := "gw_ledger".primitive_get_root((o_body ->> 'function_root')::BYTEA);
    IF o_body is null  THEN
      RETURN "gw_ledger".result_error(v_call_context,'missing-function-body');
    ELSIF (o_body ->> 'op_kind')::TEXT = 'local' THEN
      RETURN "gw_ledger".execute_local(v_call_context,v_body_root);
    ELSIF (o_body ->> 'op_kind')::TEXT = 'constant' THEN
      RETURN "gw_ledger".execute_constant(v_call_context,v_body_root);
    ELSIF ((o_body ->> 'op_kind')::TEXT = 'invoke') AND o_body_primitive IS NOT NULL AND ((o_body_primitive ->> 'primitive_id')::TEXT = 'integer/add') AND ("gw_ledger".cell_ref_count(v_body_root,'op-child') = 2) THEN
      RETURN "gw_ledger".execute_integer_add(
        v_call_context,
        "gw_ledger".op_child_root(v_body_root,0),
        "gw_ledger".op_child_root(v_body_root,1)
      );
    ELSIF ((o_body ->> 'op_kind')::TEXT = 'invoke') AND o_body_primitive IS NOT NULL AND ((o_body_primitive ->> 'primitive_id')::TEXT = 'integer/multiply') AND ("gw_ledger".cell_ref_count(v_body_root,'op-child') = 2) THEN
      RETURN "gw_ledger".execute_integer_multiply(
        v_call_context,
        "gw_ledger".op_child_root(v_body_root,0),
        "gw_ledger".op_child_root(v_body_root,1)
      );
    ELSE
      RETURN "gw_ledger".result_error(v_call_context,'unsupported-function-body');
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime/execute-function-invoke [418] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_function_invoke(
  i_context_root BYTEA,
  i_op_root BYTEA,
  i_function_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_function JSONB;
    v_parameter_count INTEGER;
  BEGIN
    o_function := "gw_ledger".function_get(i_function_root);
    IF o_function is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'unknown-function');
    END IF;
    v_parameter_count := "gw_ledger".cell_ref_count((o_function ->> 'parameters_root')::BYTEA,'element');
    IF v_parameter_count = 0 THEN
      RETURN "gw_ledger".execute_function_invoke_zero(i_context_root,i_op_root,i_function_root);
    ELSIF v_parameter_count = 1 THEN
      RETURN "gw_ledger".execute_function_invoke_one(i_context_root,i_op_root,i_function_root);
    ELSE
      RETURN "gw_ledger".result_error(i_context_root,'unsupported-function-arity');
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime/execute-invoke [436] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_invoke(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_context JSONB;
    o_function JSONB;
    o_op JSONB;
    o_primitive JSONB;
    v_count INTEGER;
    v_left_op BYTEA;
    v_right_op BYTEA;
  BEGIN
    o_context := "gw_ledger".context_get(i_context_root);
    o_op := "gw_ledger".op_get(i_op_root);
    IF o_context is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'missing-context');
    END IF;
    IF NOT "gw_ledger".op_valid(i_op_root) THEN
      RETURN "gw_ledger".result_error(i_context_root,'invalid-op');
    END IF;
    IF NOT ((o_op ->> 'op_kind')::TEXT = 'invoke') THEN
      RETURN "gw_ledger".result_error(i_context_root,'wrong-op-kind');
    END IF;
    o_primitive := "gw_ledger".primitive_get_root((o_op ->> 'function_root')::BYTEA);
    o_function := "gw_ledger".function_get((o_op ->> 'function_root')::BYTEA);
    v_count := "gw_ledger".cell_ref_count(i_op_root,'op-child');
    IF o_primitive IS NULL AND o_function IS NULL THEN
      RETURN "gw_ledger".result_error(i_context_root,'unknown-callable');
    END IF;
    IF o_function is not null  THEN
      RETURN "gw_ledger".execute_function_invoke(i_context_root,i_op_root,(o_op ->> 'function_root')::BYTEA);
    END IF;
    IF NOT ((((o_primitive ->> 'primitive_id')::TEXT = 'integer/add') OR ((o_primitive ->> 'primitive_id')::TEXT = 'integer/multiply')) AND ((o_primitive ->> 'arity')::INTEGER = 2) AND (v_count = 2)) THEN
      RETURN "gw_ledger".result_error(i_context_root,'arity');
    END IF;
    v_left_op := "gw_ledger".op_child_root(i_op_root,0);
    v_right_op := "gw_ledger".op_child_root(i_op_root,1);
    IF (o_primitive ->> 'primitive_id')::TEXT = 'integer/add' THEN
      RETURN "gw_ledger".execute_integer_add(i_context_root,v_left_op,v_right_op);
    ELSE
      RETURN "gw_ledger".execute_integer_multiply(i_context_root,v_left_op,v_right_op);
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime/execute-def [471] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_def(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_context JSONB;
    o_op JSONB;
    o_value_op JSONB;
    o_value_result JSONB;
    v_account_root BYTEA;
    v_next_account BYTEA;
    v_next_context BYTEA;
    v_next_state BYTEA;
    v_state_context BYTEA;
    v_value_op_root BYTEA;
  BEGIN
    o_context := "gw_ledger".context_get(i_context_root);
    o_op := "gw_ledger".op_get(i_op_root);
    IF o_context is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'missing-context');
    END IF;
    IF NOT "gw_ledger".op_valid(i_op_root) THEN
      RETURN "gw_ledger".result_error(i_context_root,'invalid-op');
    END IF;
    IF NOT ((o_op ->> 'op_kind')::TEXT = 'def') THEN
      RETURN "gw_ledger".result_error(i_context_root,'wrong-op-kind');
    END IF;
    IF NOT "gw_ledger".context_can_charge(i_context_root,3) THEN
      RETURN "gw_ledger".result_error(i_context_root,'cost-limit');
    END IF;
    v_value_op_root := "gw_ledger".op_child_root(i_op_root,0);
    o_value_op := "gw_ledger".op_get(v_value_op_root);
    IF o_value_op IS NULL OR NOT ((o_value_op ->> 'op_kind')::TEXT = 'constant') THEN
      RETURN "gw_ledger".result_error(i_context_root,'unsupported-definition');
    END IF;
    o_value_result := "gw_ledger".execute_constant(i_context_root,v_value_op_root);
    IF (o_value_result ->> 'status')::TEXT = 'error' THEN
      RETURN o_value_result;
    END IF;
    v_account_root := "gw_ledger".state_account_root(
      (o_context ->> 'state_root')::BYTEA,
      (o_context ->> 'address')::BYTEA
    );
    IF v_account_root is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'missing-account');
    END IF;
    v_next_account := "gw_ledger".account_value_define(
      v_account_root,
      (o_op ->> 'symbol_root')::BYTEA,
      (o_value_result ->> 'value_root')::BYTEA
    );
    v_next_state := "gw_ledger".state_assoc_account(
      (o_context ->> 'state_root')::BYTEA,
      (o_context ->> 'address')::BYTEA,
      v_next_account,
      (o_context ->> 'block_height')::BIGINT
    );
    v_state_context := "gw_ledger".context_with_state((o_value_result ->> 'context_root')::BYTEA,v_next_state);
    v_next_context := "gw_ledger".context_charge(v_state_context,2);
    RETURN "gw_ledger".result_ok(v_next_context,(o_value_result ->> 'value_root')::BYTEA);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime/execute-cond-step [515] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_cond_step(
  i_context_root BYTEA,
  i_op_root BYTEA,
  i_position INTEGER,
  i_count INTEGER
) RETURNS JSONB AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN "gw_ledger".result_ok(i_context_root,"gw_ledger".put_nil());
  ELSE
    DECLARE
    o_body_op JSONB;
      o_test_cell JSONB;
      o_test_op JSONB;
      o_test_result JSONB;
      v_body_root BYTEA;
      v_test_root BYTEA;
      v_true BOOLEAN;
  BEGIN
    v_test_root := "gw_ledger".op_child_root(i_op_root,i_position);
      v_body_root := "gw_ledger".op_child_root(i_op_root,i_position + 1);
      o_test_op := "gw_ledger".op_get(v_test_root);
      o_body_op := "gw_ledger".op_get(v_body_root);
      o_test_result := CASE WHEN o_test_op IS NULL THEN "gw_ledger".result_error(i_context_root,'invalid-condition')
      WHEN (o_test_op ->> 'op_kind')::TEXT = 'constant' THEN "gw_ledger".execute_constant(i_context_root,v_test_root)
      ELSE "gw_ledger".result_error(i_context_root,'unsupported-condition')
      END;
      o_test_cell := "gw_ledger".cell_by_hash((o_test_result ->> 'value_root')::BYTEA);
      v_true := (((o_test_cell ->> 'type_tag')::SMALLINT = 1) AND ((o_test_cell ->> 'payload')::BYTEA = decode('01','hex')));
      IF (o_test_result ->> 'status')::TEXT = 'error' THEN
        RETURN o_test_result;
      ELSIF NOT v_true THEN
        RETURN "gw_ledger".execute_cond_step(
          (o_test_result ->> 'context_root')::BYTEA,
          i_op_root,
          i_position + 2,
          i_count
        );
      ELSIF o_body_op is null  THEN
        RETURN "gw_ledger".result_error((o_test_result ->> 'context_root')::BYTEA,'missing-branch');
      ELSIF (o_body_op ->> 'op_kind')::TEXT = 'constant' THEN
        RETURN "gw_ledger".execute_constant((o_test_result ->> 'context_root')::BYTEA,v_body_root);
      ELSIF (o_body_op ->> 'op_kind')::TEXT = 'invoke' THEN
        RETURN "gw_ledger".execute_invoke((o_test_result ->> 'context_root')::BYTEA,v_body_root);
      ELSE
        RETURN "gw_ledger".result_error(
          (o_test_result ->> 'context_root')::BYTEA,
          'unsupported-branch'
        );
      END IF;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime/execute-cond [559] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_cond(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    v_count INTEGER;
  BEGIN
    v_count := "gw_ledger".cell_ref_count(i_op_root,'op-child');
    IF NOT ((v_count % 2) = 0) THEN
      RETURN "gw_ledger".result_error(i_context_root,'uneven-condition-children');
    ELSE
      RETURN "gw_ledger".execute_cond_step(i_context_root,i_op_root,0,v_count);
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime/execute-do-step [568] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_do_step(
  i_context_root BYTEA,
  i_op_root BYTEA,
  i_position INTEGER,
  i_count INTEGER,
  i_last_result JSONB
) RETURNS JSONB AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN i_last_result;
  ELSE
    DECLARE
    o_child JSONB;
      o_result JSONB;
      v_child_root BYTEA;
  BEGIN
    v_child_root := "gw_ledger".op_child_root(i_op_root,i_position);
      o_child := "gw_ledger".op_get(v_child_root);
      o_result := CASE WHEN o_child IS NULL THEN "gw_ledger".result_error(i_context_root,'invalid-op')
      WHEN (o_child ->> 'op_kind')::TEXT = 'constant' THEN "gw_ledger".execute_constant(i_context_root,v_child_root)
      WHEN (o_child ->> 'op_kind')::TEXT = 'special' THEN "gw_ledger".execute_special(i_context_root,v_child_root)
      WHEN (o_child ->> 'op_kind')::TEXT = 'lookup' THEN "gw_ledger".execute_lookup(i_context_root,v_child_root)
      WHEN (o_child ->> 'op_kind')::TEXT = 'local' THEN "gw_ledger".execute_local(i_context_root,v_child_root)
      WHEN (o_child ->> 'op_kind')::TEXT = 'let' THEN "gw_ledger".execute_let(i_context_root,v_child_root)
      WHEN (o_child ->> 'op_kind')::TEXT = 'lambda' THEN "gw_ledger".execute_lambda(i_context_root,v_child_root)
      WHEN (o_child ->> 'op_kind')::TEXT = 'invoke' THEN "gw_ledger".execute_invoke(i_context_root,v_child_root)
      WHEN (o_child ->> 'op_kind')::TEXT = 'def' THEN "gw_ledger".execute_def(i_context_root,v_child_root)
      WHEN (o_child ->> 'op_kind')::TEXT = 'cond' THEN "gw_ledger".execute_cond(i_context_root,v_child_root)
      ELSE "gw_ledger".result_error(i_context_root,'unsupported-do-child')
      END;
      IF (o_result ->> 'status')::TEXT = 'error' THEN
        RETURN o_result;
      ELSE
        RETURN "gw_ledger".execute_do_step(
          (o_result ->> 'context_root')::BYTEA,
          i_op_root,
          i_position + 1,
          i_count,
          o_result
        );
      END IF;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime/execute-do [607] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_do(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    v_count INTEGER;
  BEGIN
    v_count := "gw_ledger".cell_ref_count(i_op_root,'op-child');
    IF v_count = 0 THEN
      RETURN "gw_ledger".result_error(i_context_root,'empty-do');
    ELSE
      RETURN "gw_ledger".execute_do_step(i_context_root,i_op_root,0,v_count,null);
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime/execute [616] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_op JSONB;
  BEGIN
    o_op := "gw_ledger".op_get(i_op_root);
    IF o_op is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'unknown-op');
    ELSIF NOT "gw_ledger".op_valid(i_op_root) THEN
      RETURN "gw_ledger".result_error(i_context_root,'invalid-op');
    ELSIF (o_op ->> 'op_kind')::TEXT = 'constant' THEN
      RETURN "gw_ledger".execute_constant(i_context_root,i_op_root);
    ELSIF (o_op ->> 'op_kind')::TEXT = 'special' THEN
      RETURN "gw_ledger".execute_special(i_context_root,i_op_root);
    ELSIF (o_op ->> 'op_kind')::TEXT = 'lookup' THEN
      RETURN "gw_ledger".execute_lookup(i_context_root,i_op_root);
    ELSIF (o_op ->> 'op_kind')::TEXT = 'local' THEN
      RETURN "gw_ledger".execute_local(i_context_root,i_op_root);
    ELSIF (o_op ->> 'op_kind')::TEXT = 'let' THEN
      RETURN "gw_ledger".execute_let(i_context_root,i_op_root);
    ELSIF (o_op ->> 'op_kind')::TEXT = 'lambda' THEN
      RETURN "gw_ledger".execute_lambda(i_context_root,i_op_root);
    ELSIF (o_op ->> 'op_kind')::TEXT = 'invoke' THEN
      RETURN "gw_ledger".execute_invoke(i_context_root,i_op_root);
    ELSIF (o_op ->> 'op_kind')::TEXT = 'def' THEN
      RETURN "gw_ledger".execute_def(i_context_root,i_op_root);
    ELSIF (o_op ->> 'op_kind')::TEXT = 'cond' THEN
      RETURN "gw_ledger".execute_cond(i_context_root,i_op_root);
    ELSIF (o_op ->> 'op_kind')::TEXT = 'do' THEN
      RETURN "gw_ledger".execute_do(i_context_root,i_op_root);
    ELSE
      RETURN "gw_ledger".result_error(i_context_root,'unsupported-op');
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pgsodium";

-- gwdb.ledger.crypto/public-key-valid [26] 
CREATE OR REPLACE FUNCTION "gw_ledger".public_key_valid(
  i_public_key BYTEA
) RETURNS BOOLEAN AS $$

  SELECT length(i_public_key) = 32;

$$ LANGUAGE 'sql' IMMUTABLE PARALLEL SAFE;

-- gwdb.ledger.crypto/signature-valid [32] 
CREATE OR REPLACE FUNCTION "gw_ledger".signature_valid(
  i_signature BYTEA
) RETURNS BOOLEAN AS $$

  SELECT length(i_signature) = 64;

$$ LANGUAGE 'sql' IMMUTABLE PARALLEL SAFE;

-- gwdb.ledger.crypto/public-key-root-valid [38] 
CREATE OR REPLACE FUNCTION "gw_ledger".public_key_root_valid(
  i_public_key_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_cell JSONB;
  BEGIN
    o_cell := "gw_ledger".cell_by_hash(i_public_key_root);
    RETURN o_cell IS NOT NULL AND ((o_cell ->> 'type_tag')::SMALLINT = 6) AND "gw_ledger".public_key_valid((o_cell ->> 'payload')::BYTEA);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.crypto/account-address-payload [48] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_address_payload(
  i_public_key BYTEA
) RETURNS BYTEA AS $$

  SELECT "gw_ledger".sha256(
    decode('gwdb-ledger:account:ed25519:v1:','escape') || i_public_key
  );

$$ LANGUAGE 'sql' IMMUTABLE PARALLEL SAFE;

-- gwdb.ledger.crypto/signature-verify [56] 
CREATE OR REPLACE FUNCTION "gw_ledger".signature_verify(
  i_signature BYTEA,
  i_message BYTEA,
  i_public_key BYTEA
) RETURNS BOOLEAN AS $$
BEGIN
  RETURN "gw_ledger".signature_valid(i_signature) AND "gw_ledger".public_key_valid(i_public_key) AND pgsodium.crypto_sign_verify_detached(i_signature,i_message,i_public_key);
END;
$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- gwdb.ledger.transaction/Transaction [30] 
DROP TABLE IF EXISTS "gw_ledger"."Transaction" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."Transaction" (
  "transaction_root" BYTEA PRIMARY KEY,
  "transaction_version" SMALLINT NOT NULL,
  "network" TEXT NOT NULL,
  "origin" BYTEA NOT NULL,
  "sequence" BIGINT NOT NULL,
  "op_root" BYTEA NOT NULL,
  "form_root" BYTEA,
  "cost_limit" BIGINT NOT NULL,
  "runtime_root" BYTEA NOT NULL,
  "signature" BYTEA,
  UNIQUE ("network","origin","sequence")
);

-- gwdb.ledger.transaction/TransactionReceipt [47] 
DROP TABLE IF EXISTS "gw_ledger"."TransactionReceipt" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."TransactionReceipt" (
  "receipt_root" BYTEA PRIMARY KEY,
  "transaction_root" BYTEA NOT NULL,
  "status" TEXT NOT NULL,
  "result_root" BYTEA,
  "previous_state_root" BYTEA NOT NULL,
  "state_root" BYTEA NOT NULL,
  "cost_used" BIGINT NOT NULL,
  "error_code" TEXT
);

-- gwdb.ledger.transaction/transaction-root-hex [59] 
CREATE OR REPLACE FUNCTION "gw_ledger".transaction_root_hex(
  i_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN CASE WHEN i_root IS NULL THEN '-'
  ELSE encode(i_root,'hex')
  END;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.transaction/transaction-signing-payload [65] 
CREATE OR REPLACE FUNCTION "gw_ledger".transaction_signing_payload(
  i_network TEXT,
  i_origin BYTEA,
  i_sequence BIGINT,
  i_op_root BYTEA,
  i_form_root BYTEA,
  i_cost_limit BIGINT,
  i_runtime_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN decode(
    'R:transaction-signing:1:8:' || i_network || ':' || "gw_ledger".transaction_root_hex(i_origin) || ':' || i_sequence || ':' || "gw_ledger".transaction_root_hex(i_op_root) || ':' || "gw_ledger".transaction_root_hex(i_form_root) || ':' || i_cost_limit || ':' || "gw_ledger".transaction_root_hex(i_runtime_root),
    'escape'
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.transaction/transaction-payload [81] 
CREATE OR REPLACE FUNCTION "gw_ledger".transaction_payload(
  i_network TEXT,
  i_origin BYTEA,
  i_sequence BIGINT,
  i_op_root BYTEA,
  i_form_root BYTEA,
  i_cost_limit BIGINT,
  i_runtime_root BYTEA,
  i_signature BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN decode(
    'R:transaction:1:9:' || i_network || ':' || "gw_ledger".transaction_root_hex(i_origin) || ':' || i_sequence || ':' || "gw_ledger".transaction_root_hex(i_op_root) || "gw_ledger".transaction_root_hex(i_form_root) || ':' || i_cost_limit || ':' || "gw_ledger".transaction_root_hex(i_runtime_root) || "gw_ledger".transaction_root_hex(i_signature),
    'escape'
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.transaction/transaction-put [98] 
CREATE OR REPLACE FUNCTION "gw_ledger".transaction_put(
  i_network TEXT,
  i_origin BYTEA,
  i_sequence BIGINT,
  i_op_root BYTEA,
  i_form_root BYTEA,
  i_cost_limit BIGINT,
  i_runtime_root BYTEA,
  i_signature BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_form JSONB;
    o_form_ref JSONB;
    o_op JSONB;
    o_op_ref JSONB;
    o_origin JSONB;
    o_origin_ref JSONB;
    o_runtime JSONB;
    o_runtime_ref JSONB;
    o_upsert JSONB;
    v_payload BYTEA;
    v_root BYTEA;
  BEGIN
    o_origin := "gw_ledger".cell_by_hash(i_origin);
    o_op := "gw_ledger".cell_by_hash(i_op_root);
    o_runtime := "gw_ledger".cell_by_hash(i_runtime_root);
    o_form := "gw_ledger".cell_by_hash(i_form_root);
    IF NOT (regexp_match(i_network,'^[a-z0-9._-]+$') IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_network','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-network'
      ;
    END IF;
    IF NOT (o_origin IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_transaction_origin',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-transaction-origin'
      ;
    END IF;
    IF NOT (o_op IS NOT NULL AND ((o_op ->> 'type_tag')::SMALLINT = 17)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/transaction_op_not_operation',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/transaction-op-not-operation'
      ;
    END IF;
    IF NOT (o_runtime IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_runtime_root','data',null))::TEXT,
        MESSAGE = 'ledger/missing-runtime-root'
      ;
    END IF;
    IF NOT (i_form_root IS NULL OR o_form IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_form_root','data',null))::TEXT,
        MESSAGE = 'ledger/missing-form-root'
      ;
    END IF;
    IF NOT ((i_sequence >= 0) AND (i_cost_limit >= 1)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_transaction_bounds',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-transaction-bounds'
      ;
    END IF;
    IF NOT (i_signature IS NULL OR "gw_ledger".signature_valid(i_signature)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_transaction_signature',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-transaction-signature'
      ;
    END IF;
    v_payload := "gw_ledger".transaction_payload(
      i_network,
      i_origin,
      i_sequence,
      i_op_root,
      i_form_root,
      i_cost_limit,
      i_runtime_root,
      i_signature
    );
    v_root := "gw_ledger".cell_put("gw_ledger".canonical_hash(14,v_payload),1,14,v_payload);
    o_origin_ref := "gw_ledger".cell_ref_put(v_root,0,'origin',i_origin);
    o_op_ref := "gw_ledger".cell_ref_put(v_root,1,'op',i_op_root);
    o_runtime_ref := "gw_ledger".cell_ref_put(v_root,2,'runtime',i_runtime_root);
    o_form_ref := CASE WHEN i_form_root IS NULL THEN null
    ELSE "gw_ledger".cell_ref_put(v_root,3,'form',i_form_root)
    END;
    WITH j_ret AS (  
      INSERT INTO "gw_ledger"."Transaction" (
        "transaction_root",
        "transaction_version",
        "network",
        "origin",
        "sequence",
        "op_root",
        "form_root",
        "cost_limit",
        "runtime_root",
        "signature"
      ) VALUES (
        (v_root)::BYTEA,
        (1)::SMALLINT,
        (i_network)::TEXT,
        (i_origin)::BYTEA,
        (i_sequence)::BIGINT,
        (i_op_root)::BYTEA,
        (i_form_root)::BYTEA,
        (i_cost_limit)::BIGINT,
        (i_runtime_root)::BYTEA,
        (i_signature)::BYTEA
      ) ON CONFLICT ("transaction_root") DO UPDATE SET ("transaction_root",
        "transaction_version",
        "network",
        "origin",
        "sequence",
        "op_root",
        "form_root",
        "cost_limit",
        "runtime_root",
        "signature") = row(
        EXCLUDED."transaction_root",
        EXCLUDED."transaction_version",
        EXCLUDED."network",
        EXCLUDED."origin",
        EXCLUDED."sequence",
        EXCLUDED."op_root",
        EXCLUDED."form_root",
        EXCLUDED."cost_limit",
        EXCLUDED."runtime_root",
        EXCLUDED."signature"
      ) RETURNING
        "transaction_root",
        "transaction_version",
        "network",
        "origin",
        "sequence",
        "op_root",
        "form_root",
        "cost_limit",
        "runtime_root",
        "signature")
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_upsert;
    RETURN v_root;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.transaction/transaction-get [141] 
CREATE OR REPLACE FUNCTION "gw_ledger".transaction_get(
  i_transaction_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT
        "transaction_root",
        "transaction_version",
        "network",
        "origin",
        "sequence",
        "op_root",
        "form_root",
        "cost_limit",
        "runtime_root",
        "signature"
      FROM "gw_ledger"."Transaction"
      WHERE "transaction_root" = i_transaction_root
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.transaction/transaction-root-valid [147] 
CREATE OR REPLACE FUNCTION "gw_ledger".transaction_root_valid(
  i_transaction_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_cell JSONB;
    o_tx JSONB;
    v_payload BYTEA;
  BEGIN
    o_cell := "gw_ledger".cell_by_hash(i_transaction_root);
    o_tx := "gw_ledger".transaction_get(i_transaction_root);
    IF o_cell IS NULL OR o_tx IS NULL THEN
      RETURN false;
    END IF;
    v_payload := "gw_ledger".transaction_payload(
      (o_tx ->> 'network')::TEXT,
      (o_tx ->> 'origin')::BYTEA,
      (o_tx ->> 'sequence')::BIGINT,
      (o_tx ->> 'op_root')::BYTEA,
      (o_tx ->> 'form_root')::BYTEA,
      (o_tx ->> 'cost_limit')::BIGINT,
      (o_tx ->> 'runtime_root')::BYTEA,
      (o_tx ->> 'signature')::BYTEA
    );
    RETURN ((o_cell ->> 'type_tag')::SMALLINT = 14) AND ((o_cell ->> 'payload')::BYTEA = v_payload) AND "gw_ledger".verify(i_transaction_root,14,v_payload) AND ("gw_ledger".cell_ref_count(i_transaction_root,'origin') = 1) AND ("gw_ledger".cell_ref_count(i_transaction_root,'op') = 1) AND ("gw_ledger".cell_ref_count(i_transaction_root,'runtime') = 1);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.transaction/transaction-signature-valid [168] 
CREATE OR REPLACE FUNCTION "gw_ledger".transaction_signature_valid(
  i_transaction_root BYTEA,
  i_state_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_controller JSONB;
    o_tx JSONB;
    v_account_root BYTEA;
    v_controller_root BYTEA;
    v_message BYTEA;
  BEGIN
    o_tx := "gw_ledger".transaction_get(i_transaction_root);
    v_account_root := CASE WHEN o_tx IS NULL THEN null
    ELSE "gw_ledger".state_account_root(i_state_root,(o_tx ->> 'origin')::BYTEA)
    END;
    v_controller_root := CASE WHEN v_account_root IS NULL THEN null
    ELSE "gw_ledger".account_value_controller_root(v_account_root)
    END;
    o_controller := "gw_ledger".cell_by_hash(v_controller_root);
    v_message := CASE WHEN o_tx IS NULL THEN null
    ELSE "gw_ledger".transaction_signing_payload(
      (o_tx ->> 'network')::TEXT,
      (o_tx ->> 'origin')::BYTEA,
      (o_tx ->> 'sequence')::BIGINT,
      (o_tx ->> 'op_root')::BYTEA,
      (o_tx ->> 'form_root')::BYTEA,
      (o_tx ->> 'cost_limit')::BIGINT,
      (o_tx ->> 'runtime_root')::BYTEA
    )
    END;
    RETURN o_tx IS NOT NULL AND v_account_root IS NOT NULL AND "gw_ledger".public_key_root_valid(v_controller_root) AND "gw_ledger".signature_verify(
      (o_tx ->> 'signature')::BYTEA,
      v_message,
      (o_controller ->> 'payload')::BYTEA
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.transaction/transaction-valid [196] 
CREATE OR REPLACE FUNCTION "gw_ledger".transaction_valid(
  i_transaction_root BYTEA,
  i_network TEXT,
  i_state_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_tx JSONB;
    v_account_root BYTEA;
  BEGIN
    o_tx := "gw_ledger".transaction_get(i_transaction_root);
    v_account_root := CASE WHEN o_tx IS NULL THEN null
    ELSE "gw_ledger".state_account_root(i_state_root,(o_tx ->> 'origin')::BYTEA)
    END;
    RETURN o_tx IS NOT NULL AND "gw_ledger".transaction_root_valid(i_transaction_root) AND "gw_ledger".state_root_valid(i_state_root) AND ((o_tx ->> 'network')::TEXT = i_network) AND "gw_ledger".op_valid((o_tx ->> 'op_root')::BYTEA) AND v_account_root IS NOT NULL AND ((o_tx ->> 'sequence')::BIGINT = "gw_ledger".integer_bigint("gw_ledger".account_value_sequence_root(v_account_root))) AND ((o_tx ->> 'cost_limit')::BIGINT >= 1);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.transaction/transaction-signed-valid [217] 
CREATE OR REPLACE FUNCTION "gw_ledger".transaction_signed_valid(
  i_transaction_root BYTEA,
  i_network TEXT,
  i_state_root BYTEA
) RETURNS BOOLEAN AS $$
BEGIN
  RETURN "gw_ledger".transaction_valid(i_transaction_root,i_network,i_state_root) AND "gw_ledger".transaction_signature_valid(i_transaction_root,i_state_root);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.transaction/receipt-payload [226] 
CREATE OR REPLACE FUNCTION "gw_ledger".receipt_payload(
  i_transaction_root BYTEA,
  i_status TEXT,
  i_result_root BYTEA,
  i_previous_state_root BYTEA,
  i_state_root BYTEA,
  i_cost_used BIGINT,
  i_error_code TEXT
) RETURNS BYTEA AS $$
BEGIN
  RETURN decode('R:receipt:1:7:' || "gw_ledger".transaction_root_hex(i_transaction_root) || i_status || ':' || "gw_ledger".transaction_root_hex(i_result_root) || "gw_ledger".transaction_root_hex(i_previous_state_root) || "gw_ledger".transaction_root_hex(i_state_root) || i_cost_used || ':' || CASE WHEN i_error_code IS NULL THEN '-'
  ELSE i_error_code
  END,'escape');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.transaction/transaction-receipt-put [242] 
CREATE OR REPLACE FUNCTION "gw_ledger".transaction_receipt_put(
  i_transaction_root BYTEA,
  i_status TEXT,
  i_result_root BYTEA,
  i_previous_state_root BYTEA,
  i_state_root BYTEA,
  i_cost_used BIGINT,
  i_error_code TEXT
) RETURNS BYTEA AS $$

  DECLARE
    o_upsert JSONB;
    v_payload BYTEA;
    v_root BYTEA;
  BEGIN
    v_payload := "gw_ledger".receipt_payload(
      i_transaction_root,
      i_status,
      i_result_root,
      i_previous_state_root,
      i_state_root,
      i_cost_used,
      i_error_code
    );
    v_root := "gw_ledger".cell_put("gw_ledger".canonical_hash(14,v_payload),1,14,v_payload);
    WITH j_ret AS (  
      INSERT INTO "gw_ledger"."TransactionReceipt" (
        "receipt_root",
        "transaction_root",
        "status",
        "result_root",
        "previous_state_root",
        "state_root",
        "cost_used",
        "error_code"
      ) VALUES (
        (v_root)::BYTEA,
        (i_transaction_root)::BYTEA,
        (i_status)::TEXT,
        (i_result_root)::BYTEA,
        (i_previous_state_root)::BYTEA,
        (i_state_root)::BYTEA,
        (i_cost_used)::BIGINT,
        (i_error_code)::TEXT
      ) ON CONFLICT ("receipt_root") DO UPDATE SET ("receipt_root",
        "transaction_root",
        "status",
        "result_root",
        "previous_state_root",
        "state_root",
        "cost_used",
        "error_code") = row(
        EXCLUDED."receipt_root",
        EXCLUDED."transaction_root",
        EXCLUDED."status",
        EXCLUDED."result_root",
        EXCLUDED."previous_state_root",
        EXCLUDED."state_root",
        EXCLUDED."cost_used",
        EXCLUDED."error_code"
      ) RETURNING
        "receipt_root",
        "transaction_root",
        "status",
        "result_root",
        "previous_state_root",
        "state_root",
        "cost_used",
        "error_code")
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_upsert;
    RETURN v_root;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.transaction/transaction-receipt-get [262] 
CREATE OR REPLACE FUNCTION "gw_ledger".transaction_receipt_get(
  i_receipt_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT
        "receipt_root",
        "transaction_root",
        "status",
        "result_root",
        "previous_state_root",
        "state_root",
        "cost_used",
        "error_code"
      FROM "gw_ledger"."TransactionReceipt"
      WHERE "receipt_root" = i_receipt_root
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.transaction/transaction-execute [270] 
CREATE OR REPLACE FUNCTION "gw_ledger".transaction_execute(
  i_transaction_root BYTEA,
  i_network TEXT,
  i_context_root BYTEA,
  i_previous_state_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_result JSONB;
    o_result_context JSONB;
    o_tx JSONB;
    v_cost_used BIGINT;
    v_execution_state BYTEA;
    v_result_root BYTEA;
    v_state_root BYTEA;
    v_status TEXT;
  BEGIN
    o_tx := "gw_ledger".transaction_get(i_transaction_root);
    IF NOT (o_tx IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_transaction','data',null))::TEXT,
        MESSAGE = 'ledger/missing-transaction'
      ;
    END IF;
    IF NOT ("gw_ledger".transaction_valid(i_transaction_root,i_network,i_previous_state_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_transaction','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-transaction'
      ;
    END IF;
    o_result := "gw_ledger".execute(i_context_root,(o_tx ->> 'op_root')::BYTEA);
    v_status := (o_result ->> 'status')::TEXT;
    v_result_root := (o_result ->> 'value_root')::BYTEA;
    v_cost_used := (o_result ->> 'cost_used')::BIGINT;
    o_result_context := "gw_ledger".context_get((o_result ->> 'context_root')::BYTEA);
    v_execution_state := (o_result_context ->> 'state_root')::BYTEA;
    v_state_root := CASE WHEN v_status = 'ok' THEN "gw_ledger".state_advance_account_sequence(
      v_execution_state,
      (o_tx ->> 'origin')::BYTEA,
      (o_result_context ->> 'block_height')::BIGINT
    )
    ELSE i_previous_state_root
    END;
    RETURN "gw_ledger".transaction_receipt_put(
      i_transaction_root,
      v_status,
      v_result_root,
      i_previous_state_root,
      v_state_root,
      v_cost_used,
      null
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.transaction/transaction-execute-signed [300] 
CREATE OR REPLACE FUNCTION "gw_ledger".transaction_execute_signed(
  i_transaction_root BYTEA,
  i_network TEXT,
  i_context_root BYTEA,
  i_previous_state_root BYTEA
) RETURNS BYTEA AS $$

  BEGIN
    IF NOT ("gw_ledger".transaction_signed_valid(i_transaction_root,i_network,i_previous_state_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_transaction_signature',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-transaction-signature'
      ;
    END IF;
    RETURN "gw_ledger".transaction_execute(
      i_transaction_root,
      i_network,
      i_context_root,
      i_previous_state_root
    );
  END;

$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- gwdb.ledger.block/Block [26] 
DROP TABLE IF EXISTS "gw_ledger"."Block" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."Block" (
  "block_root" BYTEA PRIMARY KEY,
  "block_version" SMALLINT NOT NULL,
  "network" TEXT NOT NULL,
  "height" BIGINT NOT NULL,
  "parent_root" BYTEA,
  "previous_state_root" BYTEA NOT NULL,
  "state_root" BYTEA NOT NULL,
  "timestamp" BIGINT NOT NULL,
  "proposer" BYTEA NOT NULL,
  "signatures_root" BYTEA
);

-- gwdb.ledger.block/BlockTransaction [40] 
DROP TABLE IF EXISTS "gw_ledger"."BlockTransaction" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."BlockTransaction" (
  "block_root" BYTEA,
  "position" INTEGER,
  "transaction_root" BYTEA NOT NULL,
  "receipt_root" BYTEA,
  PRIMARY KEY (block_root,position)
);

-- gwdb.ledger.block/BlockSignature [48] 
DROP TABLE IF EXISTS "gw_ledger"."BlockSignature" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."BlockSignature" (
  "block_root" BYTEA,
  "signer" BYTEA,
  "signature" BYTEA NOT NULL,
  PRIMARY KEY (block_root,signer)
);

-- gwdb.ledger.block/Head [55] 
DROP TABLE IF EXISTS "gw_ledger"."Head" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."Head" (
  "network" TEXT PRIMARY KEY,
  "height" BIGINT NOT NULL,
  "block_root" BYTEA NOT NULL,
  "state_root" BYTEA NOT NULL,
  "updated_at" BIGINT NOT NULL DEFAULT (1000000 * extract(epoch FROM now()))::BIGINT
);

-- gwdb.ledger.block/block-root-hex [64] 
CREATE OR REPLACE FUNCTION "gw_ledger".block_root_hex(
  i_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN CASE WHEN i_root IS NULL THEN '-'
  ELSE encode(i_root,'hex')
  END;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.block/block-payload [69] 
CREATE OR REPLACE FUNCTION "gw_ledger".block_payload(
  i_network TEXT,
  i_height BIGINT,
  i_parent_root BYTEA,
  i_previous_state_root BYTEA,
  i_state_root BYTEA,
  i_timestamp BIGINT,
  i_proposer BYTEA,
  i_signatures_root BYTEA,
  i_transaction_roots JSONB
) RETURNS BYTEA AS $$

  DECLARE
    v_prefix TEXT;
    v_transactions BYTEA;
  BEGIN
    v_transactions := "gw_ledger".sequence_payload(i_transaction_roots);
    v_prefix := ('R:block:1:' || i_network || ':' || i_height || ':' || "gw_ledger".block_root_hex(i_parent_root) || "gw_ledger".block_root_hex(i_previous_state_root) || "gw_ledger".block_root_hex(i_state_root) || i_timestamp || ':' || "gw_ledger".block_root_hex(i_proposer) || "gw_ledger".block_root_hex(i_signatures_root) || ':');
    RETURN decode(v_prefix,'escape') || v_transactions;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.block/block-transaction-refs-put [85] 
CREATE OR REPLACE FUNCTION "gw_ledger".block_transaction_refs_put(
  i_block_root BYTEA,
  i_transaction_roots JSONB,
  i_position INTEGER,
  i_count INTEGER
) RETURNS JSONB AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN null;
  ELSE
    DECLARE
    o_next JSONB;
      o_ref JSONB;
      o_row JSONB;
      v_transaction_root BYTEA;
  BEGIN
    v_transaction_root := "gw_ledger".child_root_at(i_transaction_roots,i_position);
      o_ref := "gw_ledger".cell_ref_put(i_block_root,i_position,'transaction',v_transaction_root);
      WITH j_ret AS (  
        INSERT INTO "gw_ledger"."BlockTransaction" ("block_root","position","transaction_root","receipt_root") VALUES (
          (i_block_root)::BYTEA,
          (i_position)::INTEGER,
          (v_transaction_root)::BYTEA,
          (null)::BYTEA
        ) ON CONFLICT ("block_root","position") DO UPDATE SET ("block_root","position","transaction_root","receipt_root") = row(
          EXCLUDED."block_root",
          EXCLUDED."position",
          EXCLUDED."transaction_root",
          EXCLUDED."receipt_root"
        ) RETURNING "block_root","position","transaction_root","receipt_root")
      SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
      o_next := "gw_ledger".block_transaction_refs_put(i_block_root,i_transaction_roots,i_position + 1,i_count);
      RETURN o_row;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.block/block-put [102] 
CREATE OR REPLACE FUNCTION "gw_ledger".block_put(
  i_network TEXT,
  i_height BIGINT,
  i_parent_root BYTEA,
  i_previous_state_root BYTEA,
  i_state_root BYTEA,
  i_timestamp BIGINT,
  i_proposer BYTEA,
  i_signatures_root BYTEA,
  i_transaction_roots JSONB
) RETURNS BYTEA AS $$

  DECLARE
    o_parent JSONB;
    o_previous_ref JSONB;
    o_proposer JSONB;
    o_proposer_ref JSONB;
    o_state_ref JSONB;
    o_transactions JSONB;
    o_upsert JSONB;
    v_count INTEGER;
    v_payload BYTEA;
    v_root BYTEA;
  BEGIN
    o_parent := "gw_ledger".cell_by_hash(i_parent_root);
    o_proposer := "gw_ledger".cell_by_hash(i_proposer);
    v_count := jsonb_array_length(i_transaction_roots);
    IF NOT (regexp_match(i_network,'^[a-z0-9._-]+$') IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_network','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-network'
      ;
    END IF;
    IF NOT ((i_height >= 0) AND (i_timestamp >= 0)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_block_bounds','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-block-bounds'
      ;
    END IF;
    IF NOT (i_parent_root IS NULL OR o_parent IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_block_parent','data',null))::TEXT,
        MESSAGE = 'ledger/missing-block-parent'
      ;
    END IF;
    IF NOT ("gw_ledger".state_root_valid(i_previous_state_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_previous_state',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-previous-state'
      ;
    END IF;
    IF NOT ("gw_ledger".state_root_valid(i_state_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_block_state','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-block-state'
      ;
    END IF;
    IF NOT (o_proposer IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_block_proposer',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-block-proposer'
      ;
    END IF;
    v_payload := "gw_ledger".block_payload(
      i_network,
      i_height,
      i_parent_root,
      i_previous_state_root,
      i_state_root,
      i_timestamp,
      i_proposer,
      i_signatures_root,
      i_transaction_roots
    );
    v_root := "gw_ledger".cell_put("gw_ledger".canonical_hash(14,v_payload),1,14,v_payload);
    o_previous_ref := "gw_ledger".cell_ref_put(v_root,0,'previous-state',i_previous_state_root);
    o_state_ref := "gw_ledger".cell_ref_put(v_root,1,'state',i_state_root);
    o_proposer_ref := "gw_ledger".cell_ref_put(v_root,2,'proposer',i_proposer);
    o_transactions := "gw_ledger".block_transaction_refs_put(v_root,i_transaction_roots,0,v_count);
    WITH j_ret AS (  
      INSERT INTO "gw_ledger"."Block" (
        "block_root",
        "block_version",
        "network",
        "height",
        "parent_root",
        "previous_state_root",
        "state_root",
        "timestamp",
        "proposer",
        "signatures_root"
      ) VALUES (
        (v_root)::BYTEA,
        (1)::SMALLINT,
        (i_network)::TEXT,
        (i_height)::BIGINT,
        (i_parent_root)::BYTEA,
        (i_previous_state_root)::BYTEA,
        (i_state_root)::BYTEA,
        (i_timestamp)::BIGINT,
        (i_proposer)::BYTEA,
        (i_signatures_root)::BYTEA
      ) ON CONFLICT ("block_root") DO UPDATE SET ("block_root",
        "block_version",
        "network",
        "height",
        "parent_root",
        "previous_state_root",
        "state_root",
        "timestamp",
        "proposer",
        "signatures_root") = row(
        EXCLUDED."block_root",
        EXCLUDED."block_version",
        EXCLUDED."network",
        EXCLUDED."height",
        EXCLUDED."parent_root",
        EXCLUDED."previous_state_root",
        EXCLUDED."state_root",
        EXCLUDED."timestamp",
        EXCLUDED."proposer",
        EXCLUDED."signatures_root"
      ) RETURNING
        "block_root",
        "block_version",
        "network",
        "height",
        "parent_root",
        "previous_state_root",
        "state_root",
        "timestamp",
        "proposer",
        "signatures_root")
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_upsert;
    RETURN v_root;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.block/block-get [142] 
CREATE OR REPLACE FUNCTION "gw_ledger".block_get(
  i_block_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT
        "block_root",
        "block_version",
        "network",
        "height",
        "parent_root",
        "previous_state_root",
        "state_root",
        "timestamp",
        "proposer",
        "signatures_root"
      FROM "gw_ledger"."Block"
      WHERE "block_root" = i_block_root
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.block/block-transaction-roots [148] 
CREATE OR REPLACE FUNCTION "gw_ledger".block_transaction_roots(
  i_block_root BYTEA,
  i_position INTEGER,
  i_count INTEGER,
  i_out JSONB
) RETURNS JSONB AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN i_out;
  ELSE
    DECLARE
    v_next JSONB;
      v_root BYTEA;
  BEGIN
    v_root := "gw_ledger".cell_ref_child(i_block_root,i_position,'transaction');
      v_next := (i_out || jsonb_build_array(encode(v_root,'hex')));
      RETURN "gw_ledger".block_transaction_roots(i_block_root,i_position + 1,i_count,v_next);
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.block/block-valid [160] 
CREATE OR REPLACE FUNCTION "gw_ledger".block_valid(
  i_block_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_block JSONB;
    o_cell JSONB;
    v_count INTEGER;
    v_payload BYTEA;
    v_transactions JSONB;
  BEGIN
    o_cell := "gw_ledger".cell_by_hash(i_block_root);
    o_block := "gw_ledger".block_get(i_block_root);
    IF o_cell IS NULL OR o_block IS NULL THEN
      RETURN false;
    END IF;
    v_count := "gw_ledger".cell_ref_count(i_block_root,'transaction');
    v_transactions := "gw_ledger".block_transaction_roots(i_block_root,0,v_count,jsonb_build_array());
    v_payload := "gw_ledger".block_payload(
      (o_block ->> 'network')::TEXT,
      (o_block ->> 'height')::BIGINT,
      (o_block ->> 'parent_root')::BYTEA,
      (o_block ->> 'previous_state_root')::BYTEA,
      (o_block ->> 'state_root')::BYTEA,
      (o_block ->> 'timestamp')::BIGINT,
      (o_block ->> 'proposer')::BYTEA,
      (o_block ->> 'signatures_root')::BYTEA,
      v_transactions
    );
    RETURN ((o_cell ->> 'type_tag')::SMALLINT = 14) AND ((o_cell ->> 'payload')::BYTEA = v_payload) AND "gw_ledger".verify(i_block_root,14,v_payload) AND ("gw_ledger".cell_ref_count(i_block_root,'previous-state') = 1) AND ("gw_ledger".cell_ref_count(i_block_root,'state') = 1) AND ("gw_ledger".cell_ref_count(i_block_root,'proposer') = 1);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.block/head-get [185] 
CREATE OR REPLACE FUNCTION "gw_ledger".head_get(
  i_network TEXT
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT "network","height","block_root","state_root","updated_at" FROM "gw_ledger"."Head"
      WHERE "network" = i_network
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.block/head-lock [191] 
CREATE OR REPLACE FUNCTION "gw_ledger".head_lock(
  i_network TEXT
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT "network","height","block_root","state_root","updated_at" FROM "gw_ledger"."Head"
      WHERE "network" = i_network
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.block/head-put [197] 
CREATE OR REPLACE FUNCTION "gw_ledger".head_put(
  i_network TEXT,
  i_height BIGINT,
  i_block_root BYTEA,
  i_state_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      INSERT INTO "gw_ledger"."Head" ("network","height","block_root","state_root") VALUES (
        (i_network)::TEXT,
        (i_height)::BIGINT,
        (i_block_root)::BYTEA,
        (i_state_root)::BYTEA
      ) ON CONFLICT ("network") DO UPDATE SET ("network","height","block_root","state_root") = row(
        EXCLUDED."network",
        EXCLUDED."height",
        EXCLUDED."block_root",
        EXCLUDED."state_root"
      ) RETURNING "network","height","block_root","state_root","updated_at")
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.block/head-commit [205] 
CREATE OR REPLACE FUNCTION "gw_ledger".head_commit(
  i_network TEXT,
  i_expected_height BIGINT,
  i_expected_state_root BYTEA,
  i_height BIGINT,
  i_block_root BYTEA,
  i_state_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_head JSONB;
  BEGIN
    o_head := "gw_ledger".head_lock(i_network);
    IF o_head is null  THEN
      IF NOT (i_expected_height = -1) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object('status','error','tag','ledger/head_missing','data',null))::TEXT,
          MESSAGE = 'ledger/head-missing'
        ;
      END IF;
      RETURN "gw_ledger".head_put(i_network,i_height,i_block_root,i_state_root);
    ELSE
      IF NOT ((o_head ->> 'height')::BIGINT = i_expected_height) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object('status','error','tag','ledger/head_height_conflict','data',null))::TEXT,
          MESSAGE = 'ledger/head-height-conflict'
        ;
      END IF;
      IF NOT ((o_head ->> 'state_root')::BYTEA = i_expected_state_root) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object('status','error','tag','ledger/head_state_conflict','data',null))::TEXT,
          MESSAGE = 'ledger/head-state-conflict'
        ;
      END IF;
      RETURN "gw_ledger".head_put(i_network,i_height,i_block_root,i_state_root);
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.block/block-commit [222] 
CREATE OR REPLACE FUNCTION "gw_ledger".block_commit(
  i_network TEXT,
  i_expected_height BIGINT,
  i_expected_state_root BYTEA,
  i_height BIGINT,
  i_parent_root BYTEA,
  i_previous_state_root BYTEA,
  i_state_root BYTEA,
  i_timestamp BIGINT,
  i_proposer BYTEA,
  i_signatures_root BYTEA,
  i_transaction_roots JSONB
) RETURNS BYTEA AS $$

  DECLARE
    o_head JSONB;
    v_block_root BYTEA;
  BEGIN
    v_block_root := "gw_ledger".block_put(
      i_network,
      i_height,
      i_parent_root,
      i_previous_state_root,
      i_state_root,
      i_timestamp,
      i_proposer,
      i_signatures_root,
      i_transaction_roots
    );
    IF NOT ("gw_ledger".block_valid(v_block_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_block','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-block'
      ;
    END IF;
    o_head := "gw_ledger".head_commit(
      i_network,
      i_expected_height,
      i_expected_state_root,
      i_height,
      v_block_root,
      i_state_root
    );
    RETURN v_block_root;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.block/block-transaction-bind [238] 
CREATE OR REPLACE FUNCTION "gw_ledger".block_transaction_bind(
  i_block_root BYTEA,
  i_position INTEGER,
  i_receipt_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
    v_transaction_root BYTEA;
  BEGIN
    v_transaction_root := "gw_ledger".cell_ref_child(i_block_root,i_position,'transaction');
    WITH j_ret AS (  
      INSERT INTO "gw_ledger"."BlockTransaction" ("block_root","position","transaction_root","receipt_root") VALUES (
        (i_block_root)::BYTEA,
        (i_position)::INTEGER,
        (v_transaction_root)::BYTEA,
        (i_receipt_root)::BYTEA
      ) ON CONFLICT ("block_root","position") DO UPDATE SET ("block_root","position","transaction_root","receipt_root") = row(
        EXCLUDED."block_root",
        EXCLUDED."position",
        EXCLUDED."transaction_root",
        EXCLUDED."receipt_root"
      ) RETURNING "block_root","position","transaction_root","receipt_root")
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.block/block-execute-transaction [250] 
CREATE OR REPLACE FUNCTION "gw_ledger".block_execute_transaction(
  i_transaction_root BYTEA,
  i_network TEXT,
  i_previous_state_root BYTEA,
  i_height BIGINT,
  i_timestamp BIGINT
) RETURNS BYTEA AS $$

  DECLARE
    o_transaction JSONB;
    v_context_root BYTEA;
  BEGIN
    o_transaction := "gw_ledger".transaction_get(i_transaction_root);
    IF NOT (o_transaction IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_transaction','data',null))::TEXT,
        MESSAGE = 'ledger/missing-transaction'
      ;
    END IF;
    v_context_root := "gw_ledger".context_create(
      i_previous_state_root,
      (o_transaction ->> 'origin')::BYTEA,
      (o_transaction ->> 'origin')::BYTEA,
      null,
      i_transaction_root,
      i_height,
      i_timestamp,
      "gw_ledger".put_vector(jsonb_build_array()),
      0,
      (o_transaction ->> 'cost_limit')::BIGINT,
      0
    );
    RETURN "gw_ledger".transaction_execute(
      i_transaction_root,
      i_network,
      v_context_root,
      i_previous_state_root
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.block/block-execute-signed-transaction [268] 
CREATE OR REPLACE FUNCTION "gw_ledger".block_execute_signed_transaction(
  i_transaction_root BYTEA,
  i_network TEXT,
  i_previous_state_root BYTEA,
  i_height BIGINT,
  i_timestamp BIGINT
) RETURNS BYTEA AS $$

  DECLARE
    o_transaction JSONB;
    v_context_root BYTEA;
  BEGIN
    o_transaction := "gw_ledger".transaction_get(i_transaction_root);
    IF NOT (o_transaction IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_transaction','data',null))::TEXT,
        MESSAGE = 'ledger/missing-transaction'
      ;
    END IF;
    v_context_root := "gw_ledger".context_create(
      i_previous_state_root,
      (o_transaction ->> 'origin')::BYTEA,
      (o_transaction ->> 'origin')::BYTEA,
      null,
      i_transaction_root,
      i_height,
      i_timestamp,
      "gw_ledger".put_vector(jsonb_build_array()),
      0,
      (o_transaction ->> 'cost_limit')::BIGINT,
      0
    );
    RETURN "gw_ledger".transaction_execute_signed(
      i_transaction_root,
      i_network,
      v_context_root,
      i_previous_state_root
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.block/block-commit-one [287] 
CREATE OR REPLACE FUNCTION "gw_ledger".block_commit_one(
  i_network TEXT,
  i_expected_height BIGINT,
  i_expected_state_root BYTEA,
  i_height BIGINT,
  i_parent_root BYTEA,
  i_previous_state_root BYTEA,
  i_state_root BYTEA,
  i_timestamp BIGINT,
  i_proposer BYTEA,
  i_signatures_root BYTEA,
  i_transaction_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_bound JSONB;
    o_receipt JSONB;
    v_block_root BYTEA;
    v_receipt_root BYTEA;
  BEGIN
    v_receipt_root := "gw_ledger".block_execute_transaction(
      i_transaction_root,
      i_network,
      i_previous_state_root,
      i_height,
      i_timestamp
    );
    o_receipt := "gw_ledger".transaction_receipt_get(v_receipt_root);
    IF NOT (o_receipt IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_receipt','data',null))::TEXT,
        MESSAGE = 'ledger/missing-receipt'
      ;
    END IF;
    IF NOT ((o_receipt ->> 'state_root')::BYTEA = i_state_root) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/block_state_root_mismatch',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/block-state-root-mismatch'
      ;
    END IF;
    v_block_root := "gw_ledger".block_commit(
      i_network,
      i_expected_height,
      i_expected_state_root,
      i_height,
      i_parent_root,
      i_previous_state_root,
      i_state_root,
      i_timestamp,
      i_proposer,
      i_signatures_root,
      jsonb_build_array(encode(i_transaction_root,'hex'))
    );
    o_bound := "gw_ledger".block_transaction_bind(v_block_root,0,v_receipt_root);
    RETURN v_block_root;
  END;

$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- gwdb.ledger.syntax/Syntax [18] 
DROP TABLE IF EXISTS "gw_ledger"."Syntax" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."Syntax" (
  "syntax_root" BYTEA PRIMARY KEY,
  "value_root" BYTEA NOT NULL,
  "metadata_root" BYTEA NOT NULL
);

-- gwdb.ledger.syntax/put-syntax [25] 
CREATE OR REPLACE FUNCTION "gw_ledger".put_syntax(
  i_value_root BYTEA,
  i_metadata_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_metadata JSONB;
    o_metadata_ref JSONB;
    o_root BYTEA;
    o_upsert JSONB;
    o_value JSONB;
    o_value_ref JSONB;
    v_payload BYTEA;
  BEGIN
    o_value := "gw_ledger".cell_by_hash(i_value_root);
    o_metadata := "gw_ledger".cell_by_hash(i_metadata_root);
    IF NOT (o_value IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_syntax_value','data',null))::TEXT,
        MESSAGE = 'ledger/missing-syntax-value'
      ;
    END IF;
    IF NOT (o_metadata IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_syntax_metadata',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-syntax-metadata'
      ;
    END IF;
    IF NOT ((o_metadata ->> 'type_tag')::SMALLINT = 11) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/syntax_metadata_not_map',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/syntax-metadata-not-map'
      ;
    END IF;
    v_payload := "gw_ledger".syntax_payload(i_value_root,i_metadata_root);
    o_root := "gw_ledger".cell_put("gw_ledger".canonical_hash(13,v_payload),1,13,v_payload);
    o_value_ref := "gw_ledger".cell_ref_put(o_root,0,'value',i_value_root);
    o_metadata_ref := "gw_ledger".cell_ref_put(o_root,1,'metadata',i_metadata_root);
    WITH j_ret AS (  
      INSERT INTO "gw_ledger"."Syntax" ("syntax_root","value_root","metadata_root") VALUES (
        (o_root)::BYTEA,
        (i_value_root)::BYTEA,
        (i_metadata_root)::BYTEA
      ) ON CONFLICT ("syntax_root") DO UPDATE SET ("syntax_root","value_root","metadata_root") = row(
        EXCLUDED."syntax_root",
        EXCLUDED."value_root",
        EXCLUDED."metadata_root"
      ) RETURNING "syntax_root","value_root","metadata_root")
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_upsert;
    RETURN o_root;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.syntax/syntax-value-root [50] 
CREATE OR REPLACE FUNCTION "gw_ledger".syntax_value_root(
  i_syntax_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT "syntax_root","value_root","metadata_root" FROM "gw_ledger"."Syntax"
      WHERE "syntax_root" = i_syntax_root
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN (o_row ->> 'value_root')::BYTEA;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.syntax/syntax-metadata-root [58] 
CREATE OR REPLACE FUNCTION "gw_ledger".syntax_metadata_root(
  i_syntax_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT "syntax_root","value_root","metadata_root" FROM "gw_ledger"."Syntax"
      WHERE "syntax_root" = i_syntax_root
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN (o_row ->> 'metadata_root')::BYTEA;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.syntax/semantic-root [66] 
CREATE OR REPLACE FUNCTION "gw_ledger".semantic_root(
  i_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_cell JSONB;
  BEGIN
    o_cell := "gw_ledger".cell_by_hash(i_root);
    IF o_cell IS NOT NULL AND ((o_cell ->> 'type_tag')::SMALLINT = 13) THEN
      RETURN "gw_ledger".syntax_value_root(i_root);
    ELSE
      RETURN i_root;
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- gwdb.ledger.module/Module [18] 
DROP TABLE IF EXISTS "gw_ledger"."Module" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."Module" (
  "module_root" BYTEA PRIMARY KEY,
  "module_name" TEXT NOT NULL,
  "module_version" TEXT NOT NULL,
  "environment_root" BYTEA NOT NULL,
  "exports_root" BYTEA NOT NULL,
  "dependencies_root" BYTEA NOT NULL,
  "source_root" BYTEA,
  "compiled_root" BYTEA,
  "metadata_root" BYTEA NOT NULL,
  "publisher" BYTEA NOT NULL,
  "signature" BYTEA,
  UNIQUE ("module_name","module_version")
);

-- gwdb.ledger.module/ModuleAlias [33] 
DROP TABLE IF EXISTS "gw_ledger"."ModuleAlias" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."ModuleAlias" (
  "module_name" TEXT,
  "alias" TEXT,
  "module_root" BYTEA NOT NULL,
  PRIMARY KEY (module_name,alias)
);

-- gwdb.ledger.module/ModuleExport [40] 
DROP TABLE IF EXISTS "gw_ledger"."ModuleExport" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."ModuleExport" (
  "module_root" BYTEA,
  "symbol_root" BYTEA,
  "value_root" BYTEA NOT NULL,
  PRIMARY KEY (module_root,symbol_root)
);

-- gwdb.ledger.module/module-root-hex [47] 
CREATE OR REPLACE FUNCTION "gw_ledger".module_root_hex(
  i_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN CASE WHEN i_root IS NULL THEN '-'
  ELSE encode(i_root,'hex')
  END;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.module/module-payload [52] 
CREATE OR REPLACE FUNCTION "gw_ledger".module_payload(
  i_module_name TEXT,
  i_module_version TEXT,
  i_environment_root BYTEA,
  i_exports_root BYTEA,
  i_dependencies_root BYTEA,
  i_source_root BYTEA,
  i_compiled_root BYTEA,
  i_metadata_root BYTEA,
  i_publisher BYTEA,
  i_signature BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN decode(
    'R:module:1:11:' || i_module_name || ':' || i_module_version || ':' || "gw_ledger".module_root_hex(i_environment_root) || "gw_ledger".module_root_hex(i_exports_root) || "gw_ledger".module_root_hex(i_dependencies_root) || "gw_ledger".module_root_hex(i_source_root) || "gw_ledger".module_root_hex(i_compiled_root) || "gw_ledger".module_root_hex(i_metadata_root) || "gw_ledger".module_root_hex(i_publisher) || "gw_ledger".module_root_hex(i_signature),
    'escape'
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.module/module-publish [71] 
CREATE OR REPLACE FUNCTION "gw_ledger".module_publish(
  i_module_name TEXT,
  i_module_version TEXT,
  i_environment_root BYTEA,
  i_exports_root BYTEA,
  i_dependencies_root BYTEA,
  i_source_root BYTEA,
  i_compiled_root BYTEA,
  i_metadata_root BYTEA,
  i_publisher BYTEA,
  i_signature BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_dependencies JSONB;
    o_dependencies_ref JSONB;
    o_environment JSONB;
    o_environment_ref JSONB;
    o_exports JSONB;
    o_exports_ref JSONB;
    o_metadata JSONB;
    o_metadata_ref JSONB;
    o_publisher JSONB;
    o_publisher_ref JSONB;
    o_upsert JSONB;
    v_payload BYTEA;
    v_root BYTEA;
  BEGIN
    o_environment := "gw_ledger".cell_by_hash(i_environment_root);
    o_exports := "gw_ledger".cell_by_hash(i_exports_root);
    o_dependencies := "gw_ledger".cell_by_hash(i_dependencies_root);
    o_metadata := "gw_ledger".cell_by_hash(i_metadata_root);
    o_publisher := "gw_ledger".cell_by_hash(i_publisher);
    IF NOT (regexp_match(i_module_name,'^[a-z][a-z0-9.]*$') IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_module_name','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-module-name'
      ;
    END IF;
    IF NOT (regexp_match(i_module_version,'^[0-9]+[.][0-9]+[.][0-9]+$') IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_module_version',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-module-version'
      ;
    END IF;
    IF NOT (o_environment IS NOT NULL AND ((o_environment ->> 'type_tag')::SMALLINT = 11)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/module_environment_not_map',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/module-environment-not-map'
      ;
    END IF;
    IF NOT (o_exports IS NOT NULL AND ((o_exports ->> 'type_tag')::SMALLINT = 12)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/module_exports_not_set',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/module-exports-not-set'
      ;
    END IF;
    IF NOT (o_dependencies IS NOT NULL AND ((o_dependencies ->> 'type_tag')::SMALLINT = 11)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/module_dependencies_not_map',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/module-dependencies-not-map'
      ;
    END IF;
    IF NOT (o_metadata IS NOT NULL AND ((o_metadata ->> 'type_tag')::SMALLINT = 11)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/module_metadata_not_map',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/module-metadata-not-map'
      ;
    END IF;
    IF NOT (o_publisher IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_module_publisher',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-module-publisher'
      ;
    END IF;
    v_payload := "gw_ledger".module_payload(
      i_module_name,
      i_module_version,
      i_environment_root,
      i_exports_root,
      i_dependencies_root,
      i_source_root,
      i_compiled_root,
      i_metadata_root,
      i_publisher,
      i_signature
    );
    v_root := "gw_ledger".cell_put("gw_ledger".canonical_hash(14,v_payload),1,14,v_payload);
    o_environment_ref := "gw_ledger".cell_ref_put(v_root,0,'environment',i_environment_root);
    o_exports_ref := "gw_ledger".cell_ref_put(v_root,1,'exports',i_exports_root);
    o_dependencies_ref := "gw_ledger".cell_ref_put(v_root,2,'dependencies',i_dependencies_root);
    o_metadata_ref := "gw_ledger".cell_ref_put(v_root,3,'metadata',i_metadata_root);
    o_publisher_ref := "gw_ledger".cell_ref_put(v_root,4,'publisher',i_publisher);
    WITH j_ret AS (  
      INSERT INTO "gw_ledger"."Module" (
        "module_root",
        "module_name",
        "module_version",
        "environment_root",
        "exports_root",
        "dependencies_root",
        "source_root",
        "compiled_root",
        "metadata_root",
        "publisher",
        "signature"
      ) VALUES (
        (v_root)::BYTEA,
        (i_module_name)::TEXT,
        (i_module_version)::TEXT,
        (i_environment_root)::BYTEA,
        (i_exports_root)::BYTEA,
        (i_dependencies_root)::BYTEA,
        (i_source_root)::BYTEA,
        (i_compiled_root)::BYTEA,
        (i_metadata_root)::BYTEA,
        (i_publisher)::BYTEA,
        (i_signature)::BYTEA
      ) ON CONFLICT ("module_root") DO UPDATE SET ("module_root",
        "module_name",
        "module_version",
        "environment_root",
        "exports_root",
        "dependencies_root",
        "source_root",
        "compiled_root",
        "metadata_root",
        "publisher",
        "signature") = row(
        EXCLUDED."module_root",
        EXCLUDED."module_name",
        EXCLUDED."module_version",
        EXCLUDED."environment_root",
        EXCLUDED."exports_root",
        EXCLUDED."dependencies_root",
        EXCLUDED."source_root",
        EXCLUDED."compiled_root",
        EXCLUDED."metadata_root",
        EXCLUDED."publisher",
        EXCLUDED."signature"
      ) RETURNING
        "module_root",
        "module_name",
        "module_version",
        "environment_root",
        "exports_root",
        "dependencies_root",
        "source_root",
        "compiled_root",
        "metadata_root",
        "publisher",
        "signature")
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_upsert;
    RETURN v_root;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.module/module-get [122] 
CREATE OR REPLACE FUNCTION "gw_ledger".module_get(
  i_module_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT
        "module_root",
        "module_name",
        "module_version",
        "environment_root",
        "exports_root",
        "dependencies_root",
        "source_root",
        "compiled_root",
        "metadata_root",
        "publisher",
        "signature"
      FROM "gw_ledger"."Module"
      WHERE "module_root" = i_module_root
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.module/module-valid [128] 
CREATE OR REPLACE FUNCTION "gw_ledger".module_valid(
  i_module_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_cell JSONB;
    o_module JSONB;
    v_payload BYTEA;
  BEGIN
    o_cell := "gw_ledger".cell_by_hash(i_module_root);
    o_module := "gw_ledger".module_get(i_module_root);
    IF o_cell IS NULL OR o_module IS NULL THEN
      RETURN false;
    END IF;
    v_payload := "gw_ledger".module_payload(
      (o_module ->> 'module_name')::TEXT,
      (o_module ->> 'module_version')::TEXT,
      (o_module ->> 'environment_root')::BYTEA,
      (o_module ->> 'exports_root')::BYTEA,
      (o_module ->> 'dependencies_root')::BYTEA,
      (o_module ->> 'source_root')::BYTEA,
      (o_module ->> 'compiled_root')::BYTEA,
      (o_module ->> 'metadata_root')::BYTEA,
      (o_module ->> 'publisher')::BYTEA,
      (o_module ->> 'signature')::BYTEA
    );
    RETURN ((o_cell ->> 'type_tag')::SMALLINT = 14) AND ((o_cell ->> 'payload')::BYTEA = v_payload) AND "gw_ledger".verify(i_module_root,14,v_payload);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.module/module-set-alias [150] 
CREATE OR REPLACE FUNCTION "gw_ledger".module_set_alias(
  i_module_name TEXT,
  i_alias TEXT,
  i_module_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    IF NOT ("gw_ledger".module_valid(i_module_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_module','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-module'
      ;
    END IF;
    WITH j_ret AS (  
      INSERT INTO "gw_ledger"."ModuleAlias" ("module_name","alias","module_root") VALUES ((i_module_name)::TEXT,(i_alias)::TEXT,(i_module_root)::BYTEA) ON CONFLICT ("module_name","alias") DO UPDATE SET ("module_name","alias","module_root") = row(
        EXCLUDED."module_name",
        EXCLUDED."alias",
        EXCLUDED."module_root"
      ) RETURNING "module_name","alias","module_root")
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.module/module-resolve-alias [159] 
CREATE OR REPLACE FUNCTION "gw_ledger".module_resolve_alias(
  i_module_name TEXT,
  i_alias TEXT
) RETURNS BYTEA AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT "module_name","alias","module_root" FROM "gw_ledger"."ModuleAlias"
      WHERE "module_name" = i_module_name AND "alias" = i_alias
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN (o_row ->> 'module_root')::BYTEA;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.module/module-export [166] 
CREATE OR REPLACE FUNCTION "gw_ledger".module_export(
  i_module_root BYTEA,
  i_symbol_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_module JSONB;
  BEGIN
    o_module := "gw_ledger".module_get(i_module_root);
    IF NOT (o_module IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_module','data',null))::TEXT,
        MESSAGE = 'ledger/missing-module'
      ;
    END IF;
    IF NOT ("gw_ledger".set_contains((o_module ->> 'exports_root')::BYTEA,i_symbol_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/non_exported_symbol','data',null))::TEXT,
        MESSAGE = 'ledger/non-exported-symbol'
      ;
    END IF;
    RETURN "gw_ledger".map_get((o_module ->> 'environment_root')::BYTEA,i_symbol_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.module/module-export-put [178] 
CREATE OR REPLACE FUNCTION "gw_ledger".module_export_put(
  i_module_root BYTEA,
  i_symbol_root BYTEA,
  i_value_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
    v_authoritative BYTEA;
  BEGIN
    v_authoritative := "gw_ledger".module_export(i_module_root,i_symbol_root);
    IF NOT (v_authoritative = i_value_root) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/module_export_projection_mismatch',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/module-export-projection-mismatch'
      ;
    END IF;
    WITH j_ret AS (  
      INSERT INTO "gw_ledger"."ModuleExport" ("module_root","symbol_root","value_root") VALUES (
        (i_module_root)::BYTEA,
        (i_symbol_root)::BYTEA,
        (i_value_root)::BYTEA
      ) ON CONFLICT ("module_root","symbol_root") DO UPDATE SET ("module_root","symbol_root","value_root") = row(
        EXCLUDED."module_root",
        EXCLUDED."symbol_root",
        EXCLUDED."value_root"
      ) RETURNING "module_root","symbol_root","value_root")
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.module/module-export-projection-get [190] 
CREATE OR REPLACE FUNCTION "gw_ledger".module_export_projection_get(
  i_module_root BYTEA,
  i_symbol_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT "module_root","symbol_root","value_root" FROM "gw_ledger"."ModuleExport"
      WHERE "module_root" = i_module_root AND "symbol_root" = i_symbol_root
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- gwdb.ledger.integrity/cell-integrity [26] 
CREATE OR REPLACE FUNCTION "gw_ledger".cell_integrity(
  i_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_cell JSONB;
  BEGIN
    o_cell := "gw_ledger".cell_by_hash(i_root);
    RETURN o_cell IS NOT NULL AND ((o_cell ->> 'codec_version')::INTEGER = 1) AND "gw_ledger".verify(
      i_root,
      (o_cell ->> 'type_tag')::INTEGER,
      (o_cell ->> 'payload')::BYTEA
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.integrity/state-integrity [38] 
CREATE OR REPLACE FUNCTION "gw_ledger".state_integrity(
  i_state_root BYTEA
) RETURNS BOOLEAN AS $$
BEGIN
  RETURN "gw_ledger".cell_integrity(i_state_root) AND "gw_ledger".state_root_valid(i_state_root) AND "gw_ledger".cell_integrity("gw_ledger".state_version_root(i_state_root)) AND "gw_ledger".cell_integrity("gw_ledger".state_accounts_root(i_state_root)) AND "gw_ledger".cell_integrity("gw_ledger".state_modules_root(i_state_root)) AND "gw_ledger".cell_integrity("gw_ledger".state_module_aliases_root(i_state_root)) AND "gw_ledger".cell_integrity("gw_ledger".state_validators_root(i_state_root)) AND "gw_ledger".cell_integrity("gw_ledger".state_settings_root(i_state_root));
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.integrity/block-integrity [52] 
CREATE OR REPLACE FUNCTION "gw_ledger".block_integrity(
  i_block_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_block JSONB;
  BEGIN
    o_block := "gw_ledger".block_get(i_block_root);
    RETURN o_block IS NOT NULL AND "gw_ledger".cell_integrity(i_block_root) AND "gw_ledger".block_valid(i_block_root) AND "gw_ledger".state_integrity((o_block ->> 'previous_state_root')::BYTEA) AND "gw_ledger".state_integrity((o_block ->> 'state_root')::BYTEA);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.integrity/head-integrity [66] 
CREATE OR REPLACE FUNCTION "gw_ledger".head_integrity(
  i_network TEXT
) RETURNS BOOLEAN AS $$

  DECLARE
    o_block JSONB;
    o_head JSONB;
  BEGIN
    o_head := "gw_ledger".head_get(i_network);
    o_block := "gw_ledger".block_get((o_head ->> 'block_root')::BYTEA);
    RETURN o_head IS NOT NULL AND o_block IS NOT NULL AND "gw_ledger".block_integrity((o_head ->> 'block_root')::BYTEA) AND ((o_head ->> 'height')::BIGINT = (o_block ->> 'height')::BIGINT) AND ((o_head ->> 'state_root')::BYTEA = (o_block ->> 'state_root')::BYTEA);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.integrity/rebuild-account-projection [81] 
CREATE OR REPLACE FUNCTION "gw_ledger".rebuild_account_projection(
  i_state_root BYTEA,
  i_address_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
    v_account_root BYTEA;
    v_sequence BIGINT;
  BEGIN
    v_account_root := "gw_ledger".state_account_root(i_state_root,i_address_root);
    IF NOT (v_account_root IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_account','data',null))::TEXT,
        MESSAGE = 'ledger/missing-account'
      ;
    END IF;
    v_sequence := "gw_ledger".integer_bigint("gw_ledger".account_value_sequence_root(v_account_root));
    o_row := "gw_ledger".account_put(
      i_address_root,
      v_sequence,
      i_state_root,
      "gw_ledger".account_value_environment_root(v_account_root),
      "gw_ledger".account_value_metadata_root(v_account_root),
      "gw_ledger".account_value_controller_root(v_account_root)
    );
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.integrity/rebuild-module-export-projection-at [97] 
CREATE OR REPLACE FUNCTION "gw_ledger".rebuild_module_export_projection_at(
  i_module_root BYTEA,
  i_exports_root BYTEA,
  i_position INTEGER,
  i_count INTEGER
) RETURNS BOOLEAN AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN true;
  ELSE
    DECLARE
    o_projection JSONB;
      v_symbol_root BYTEA;
      v_value_root BYTEA;
  BEGIN
    v_symbol_root := "gw_ledger".cell_ref_child(i_exports_root,i_position,'element');
      v_value_root := "gw_ledger".module_export(i_module_root,v_symbol_root);
      o_projection := "gw_ledger".module_export_put(i_module_root,v_symbol_root,v_value_root);
      RETURN "gw_ledger".rebuild_module_export_projection_at(i_module_root,i_exports_root,i_position + 1,i_count);
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.integrity/rebuild-module-export-projection [112] 
CREATE OR REPLACE FUNCTION "gw_ledger".rebuild_module_export_projection(
  i_module_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_module JSONB;
    v_count INTEGER;
    v_exports_root BYTEA;
  BEGIN
    o_module := "gw_ledger".module_get(i_module_root);
    IF NOT (o_module IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_module','data',null))::TEXT,
        MESSAGE = 'ledger/missing-module'
      ;
    END IF;
    v_exports_root := (o_module ->> 'exports_root')::BYTEA;
    v_count := "gw_ledger".cell_ref_count(v_exports_root,'element');
    RETURN "gw_ledger".rebuild_module_export_projection_at(i_module_root,v_exports_root,0,v_count);
  END;

$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- gwdb.ledger.developer/developer-address-root [27] 
CREATE OR REPLACE FUNCTION "gw_ledger".developer_address_root(
  i_address TEXT
) RETURNS BYTEA AS $$

  BEGIN
    IF NOT (regexp_match(i_address,'^[a-z][a-z0-9._-]{0,62}$') IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_developer_address',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-developer-address'
      ;
    END IF;
    RETURN "gw_ledger".put_string(i_address);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.developer/developer-proposer-root [36] 
CREATE OR REPLACE FUNCTION "gw_ledger".developer_proposer_root() RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_symbol('gwdb.ledger.developer');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.developer/developer-genesis [42] 
CREATE OR REPLACE FUNCTION "gw_ledger".developer_genesis(
  i_network TEXT,
  i_timestamp BIGINT
) RETURNS BYTEA AS $$

  DECLARE
    o_head JSONB;
    v_block_root BYTEA;
    v_state_root BYTEA;
  BEGIN
    o_head := "gw_ledger".head_lock(i_network);
    IF NOT (o_head IS NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/developer_network_exists',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/developer-network-exists'
      ;
    END IF;
    v_state_root := "gw_ledger".state_genesis();
    v_block_root := "gw_ledger".block_commit(
      i_network,
      -1,
      null,
      0,
      null,
      v_state_root,
      v_state_root,
      i_timestamp,
      "gw_ledger".developer_proposer_root(),
      null,
      jsonb_build_array()
    );
    RETURN v_block_root;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.developer/developer-create-account [56] 
CREATE OR REPLACE FUNCTION "gw_ledger".developer_create_account(
  i_network TEXT,
  i_address TEXT,
  i_timestamp BIGINT
) RETURNS JSONB AS $$

  DECLARE
    o_head JSONB;
    v_account_root BYTEA;
    v_address_root BYTEA;
    v_block_root BYTEA;
    v_existing BYTEA;
    v_previous_height BIGINT;
    v_previous_state BYTEA;
    v_state_root BYTEA;
  BEGIN
    o_head := "gw_ledger".head_lock(i_network);
    IF NOT (o_head IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/developer_network_missing',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/developer-network-missing'
      ;
    END IF;
    v_previous_state := (o_head ->> 'state_root')::BYTEA;
    v_previous_height := (o_head ->> 'height')::BIGINT;
    v_address_root := "gw_ledger".developer_address_root(i_address);
    v_existing := "gw_ledger".state_account_root(v_previous_state,v_address_root);
    IF NOT (v_existing IS NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/developer_account_exists',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/developer-account-exists'
      ;
    END IF;
    v_account_root := "gw_ledger".account_value_create("gw_ledger".put_nil());
    v_state_root := "gw_ledger".state_assoc_account(
      v_previous_state,
      v_address_root,
      v_account_root,
      v_previous_height + 1
    );
    v_block_root := "gw_ledger".block_commit(
      i_network,
      v_previous_height,
      v_previous_state,
      v_previous_height + 1,
      (o_head ->> 'block_root')::BYTEA,
      v_previous_state,
      v_state_root,
      i_timestamp,
      "gw_ledger".developer_proposer_root(),
      null,
      jsonb_build_array()
    );
    RETURN jsonb_build_object(
      'address',
      i_address,
      'address_root',
      encode(v_address_root,'hex'),
      'state_root',
      encode(v_state_root,'hex'),
      'block_root',
      encode(v_block_root,'hex')
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.developer/developer-submit-integer [85] 
CREATE OR REPLACE FUNCTION "gw_ledger".developer_submit_integer(
  i_network TEXT,
  i_address TEXT,
  i_integer TEXT,
  i_cost_limit BIGINT,
  i_timestamp BIGINT
) RETURNS JSONB AS $$

  DECLARE
    o_bound JSONB;
    o_head JSONB;
    o_receipt JSONB;
    v_account_root BYTEA;
    v_address_root BYTEA;
    v_block_root BYTEA;
    v_previous_height BIGINT;
    v_previous_state BYTEA;
    v_receipt_root BYTEA;
    v_sequence BIGINT;
    v_state_root BYTEA;
    v_transaction_root BYTEA;
  BEGIN
    o_head := "gw_ledger".head_lock(i_network);
    IF NOT (o_head IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/developer_network_missing',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/developer-network-missing'
      ;
    END IF;
    v_previous_state := (o_head ->> 'state_root')::BYTEA;
    v_previous_height := (o_head ->> 'height')::BIGINT;
    v_address_root := "gw_ledger".developer_address_root(i_address);
    v_account_root := "gw_ledger".state_account_root(v_previous_state,v_address_root);
    IF NOT (v_account_root IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_account','data',null))::TEXT,
        MESSAGE = 'ledger/missing-account'
      ;
    END IF;
    v_sequence := "gw_ledger".integer_bigint("gw_ledger".account_value_sequence_root(v_account_root));
    v_transaction_root := "gw_ledger".transaction_put(
      i_network,
      v_address_root,
      v_sequence,
      "gw_ledger".constant("gw_ledger".put_integer(i_integer)),
      null,
      i_cost_limit,
      "gw_ledger".put_integer('1'),
      null
    );
    v_receipt_root := "gw_ledger".block_execute_transaction(
      v_transaction_root,
      i_network,
      v_previous_state,
      v_previous_height + 1,
      i_timestamp
    );
    o_receipt := "gw_ledger".transaction_receipt_get(v_receipt_root);
    v_state_root := (o_receipt ->> 'state_root')::BYTEA;
    v_block_root := "gw_ledger".block_commit(
      i_network,
      v_previous_height,
      v_previous_state,
      v_previous_height + 1,
      (o_head ->> 'block_root')::BYTEA,
      v_previous_state,
      v_state_root,
      i_timestamp,
      "gw_ledger".developer_proposer_root(),
      null,
      jsonb_build_array(encode(v_transaction_root,'hex'))
    );
    o_bound := "gw_ledger".block_transaction_bind(v_block_root,0,v_receipt_root);
    RETURN jsonb_build_object(
      'transaction_root',
      encode(v_transaction_root,'hex'),
      'receipt_root',
      encode(v_receipt_root,'hex'),
      'state_root',
      encode(v_state_root,'hex'),
      'block_root',
      encode(v_block_root,'hex'),
      'status',
      (o_receipt ->> 'status')::TEXT
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.developer/developer-head [125] 
CREATE OR REPLACE FUNCTION "gw_ledger".developer_head(
  i_network TEXT
) RETURNS JSONB AS $$

  DECLARE
    o_head JSONB;
  BEGIN
    o_head := "gw_ledger".head_get(i_network);
    IF NOT (o_head IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/developer_network_missing',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/developer-network-missing'
      ;
    END IF;
    RETURN jsonb_build_object(
      'network',
      i_network,
      'height',
      (o_head ->> 'height')::BIGINT,
      'block_root',
      encode((o_head ->> 'block_root')::BYTEA,'hex'),
      'state_root',
      encode((o_head ->> 'state_root')::BYTEA,'hex')
    );
  END;

$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pgsodium";

-- gwdb.ledger.admission/admission-registration-payload [29] 
CREATE OR REPLACE FUNCTION "gw_ledger".admission_registration_payload(
  i_network TEXT,
  i_public_key BYTEA
) RETURNS BYTEA AS $$

  SELECT decode(
    'R:account-registration:1:' || i_network || ':' || encode(i_public_key,'hex'),
    'escape'
  );

$$ LANGUAGE 'sql' IMMUTABLE PARALLEL SAFE;

-- gwdb.ledger.admission/admission-address-root [39] 
CREATE OR REPLACE FUNCTION "gw_ledger".admission_address_root(
  i_public_key BYTEA
) RETURNS BYTEA AS $$

  BEGIN
    IF NOT ("gw_ledger".public_key_valid(i_public_key)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_controller_key',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-controller-key'
      ;
    END IF;
    RETURN "gw_ledger".put_blob("gw_ledger".account_address_payload(i_public_key));
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.admission/admission-controller-root [49] 
CREATE OR REPLACE FUNCTION "gw_ledger".admission_controller_root(
  i_public_key BYTEA
) RETURNS BYTEA AS $$

  BEGIN
    IF NOT ("gw_ledger".public_key_valid(i_public_key)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_controller_key',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-controller-key'
      ;
    END IF;
    RETURN "gw_ledger".put_blob(i_public_key);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.admission/admission-proposer-root [57] 
CREATE OR REPLACE FUNCTION "gw_ledger".admission_proposer_root() RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_symbol('gwdb.ledger.admission');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.admission/admission-registration-signing-request [63] 
CREATE OR REPLACE FUNCTION "gw_ledger".admission_registration_signing_request(
  i_network TEXT,
  i_public_key BYTEA
) RETURNS JSONB AS $$

  DECLARE
    v_payload BYTEA;
  BEGIN
    IF NOT ("gw_ledger".public_key_valid(i_public_key)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_controller_key',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-controller-key'
      ;
    END IF;
    v_payload := "gw_ledger".admission_registration_payload(i_network,i_public_key);
    RETURN jsonb_build_object(
      'public_key',
      encode(i_public_key,'hex'),
      'signing_payload',
      encode(v_payload,'hex')
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.admission/admission-register-account [77] 
CREATE OR REPLACE FUNCTION "gw_ledger".admission_register_account(
  i_network TEXT,
  i_public_key BYTEA,
  i_signature BYTEA,
  i_timestamp BIGINT
) RETURNS JSONB AS $$

  DECLARE
    o_head JSONB;
    v_account_root BYTEA;
    v_address_root BYTEA;
    v_block_root BYTEA;
    v_controller_root BYTEA;
    v_existing BYTEA;
    v_previous_height BIGINT;
    v_previous_state BYTEA;
    v_state_root BYTEA;
  BEGIN
    IF NOT ("gw_ledger".signature_verify(
      i_signature,
      "gw_ledger".admission_registration_payload(i_network,i_public_key),
      i_public_key
    )) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_account_registration_signature',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-account-registration-signature'
      ;
    END IF;
    o_head := "gw_ledger".head_lock(i_network);
    IF NOT (o_head IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/network_missing','data',null))::TEXT,
        MESSAGE = 'ledger/network-missing'
      ;
    END IF;
    v_previous_state := (o_head ->> 'state_root')::BYTEA;
    v_previous_height := (o_head ->> 'height')::BIGINT;
    v_address_root := "gw_ledger".admission_address_root(i_public_key);
    v_existing := "gw_ledger".state_account_root(v_previous_state,v_address_root);
    IF NOT (v_existing IS NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/account_exists','data',null))::TEXT,
        MESSAGE = 'ledger/account-exists'
      ;
    END IF;
    v_controller_root := "gw_ledger".admission_controller_root(i_public_key);
    v_account_root := "gw_ledger".account_value_create(v_controller_root);
    v_state_root := "gw_ledger".state_assoc_account(
      v_previous_state,
      v_address_root,
      v_account_root,
      v_previous_height + 1
    );
    v_block_root := "gw_ledger".block_commit(
      i_network,
      v_previous_height,
      v_previous_state,
      v_previous_height + 1,
      (o_head ->> 'block_root')::BYTEA,
      v_previous_state,
      v_state_root,
      i_timestamp,
      "gw_ledger".admission_proposer_root(),
      null,
      jsonb_build_array()
    );
    RETURN jsonb_build_object(
      'address',
      encode(v_address_root,'hex'),
      'public_key',
      encode(i_public_key,'hex'),
      'state_root',
      encode(v_state_root,'hex'),
      'block_root',
      encode(v_block_root,'hex')
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.admission/admission-integer-signing-request [113] 
CREATE OR REPLACE FUNCTION "gw_ledger".admission_integer_signing_request(
  i_network TEXT,
  i_public_key BYTEA,
  i_integer TEXT,
  i_cost_limit BIGINT
) RETURNS JSONB AS $$

  DECLARE
    o_head JSONB;
    v_account_root BYTEA;
    v_address_root BYTEA;
    v_controller_root BYTEA;
    v_expected_controller BYTEA;
    v_op_root BYTEA;
    v_payload BYTEA;
    v_runtime_root BYTEA;
    v_sequence BIGINT;
    v_state_root BYTEA;
  BEGIN
    o_head := "gw_ledger".head_get(i_network);
    IF NOT (o_head IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/network_missing','data',null))::TEXT,
        MESSAGE = 'ledger/network-missing'
      ;
    END IF;
    v_state_root := (o_head ->> 'state_root')::BYTEA;
    v_address_root := "gw_ledger".admission_address_root(i_public_key);
    v_account_root := "gw_ledger".state_account_root(v_state_root,v_address_root);
    IF NOT (v_account_root IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_account','data',null))::TEXT,
        MESSAGE = 'ledger/missing-account'
      ;
    END IF;
    v_controller_root := "gw_ledger".account_value_controller_root(v_account_root);
    v_expected_controller := "gw_ledger".admission_controller_root(i_public_key);
    IF NOT (v_controller_root = v_expected_controller) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/controller_mismatch','data',null))::TEXT,
        MESSAGE = 'ledger/controller-mismatch'
      ;
    END IF;
    v_sequence := "gw_ledger".integer_bigint("gw_ledger".account_value_sequence_root(v_account_root));
    v_op_root := "gw_ledger".constant("gw_ledger".put_integer(i_integer));
    v_runtime_root := "gw_ledger".put_integer('1');
    v_payload := "gw_ledger".transaction_signing_payload(
      i_network,
      v_address_root,
      v_sequence,
      v_op_root,
      null,
      i_cost_limit,
      v_runtime_root
    );
    RETURN jsonb_build_object(
      'address',
      encode(v_address_root,'hex'),
      'sequence',
      v_sequence,
      'signing_payload',
      encode(v_payload,'hex')
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.admission/admission-submit-integer [141] 
CREATE OR REPLACE FUNCTION "gw_ledger".admission_submit_integer(
  i_network TEXT,
  i_public_key BYTEA,
  i_sequence BIGINT,
  i_integer TEXT,
  i_cost_limit BIGINT,
  i_signature BYTEA,
  i_timestamp BIGINT
) RETURNS JSONB AS $$

  DECLARE
    o_bound JSONB;
    o_head JSONB;
    o_receipt JSONB;
    v_account_root BYTEA;
    v_address_root BYTEA;
    v_block_root BYTEA;
    v_controller_root BYTEA;
    v_current_sequence BIGINT;
    v_expected_controller BYTEA;
    v_op_root BYTEA;
    v_previous_height BIGINT;
    v_previous_state BYTEA;
    v_receipt_root BYTEA;
    v_runtime_root BYTEA;
    v_state_root BYTEA;
    v_transaction_root BYTEA;
  BEGIN
    o_head := "gw_ledger".head_lock(i_network);
    IF NOT (o_head IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/network_missing','data',null))::TEXT,
        MESSAGE = 'ledger/network-missing'
      ;
    END IF;
    v_previous_state := (o_head ->> 'state_root')::BYTEA;
    v_previous_height := (o_head ->> 'height')::BIGINT;
    v_address_root := "gw_ledger".admission_address_root(i_public_key);
    v_account_root := "gw_ledger".state_account_root(v_previous_state,v_address_root);
    IF NOT (v_account_root IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_account','data',null))::TEXT,
        MESSAGE = 'ledger/missing-account'
      ;
    END IF;
    v_controller_root := "gw_ledger".account_value_controller_root(v_account_root);
    v_expected_controller := "gw_ledger".admission_controller_root(i_public_key);
    IF NOT (v_controller_root = v_expected_controller) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/controller_mismatch','data',null))::TEXT,
        MESSAGE = 'ledger/controller-mismatch'
      ;
    END IF;
    v_current_sequence := "gw_ledger".integer_bigint("gw_ledger".account_value_sequence_root(v_account_root));
    IF NOT (v_current_sequence = i_sequence) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/sequence_conflict','data',null))::TEXT,
        MESSAGE = 'ledger/sequence-conflict'
      ;
    END IF;
    v_op_root := "gw_ledger".constant("gw_ledger".put_integer(i_integer));
    v_runtime_root := "gw_ledger".put_integer('1');
    v_transaction_root := "gw_ledger".transaction_put(
      i_network,
      v_address_root,
      i_sequence,
      v_op_root,
      null,
      i_cost_limit,
      v_runtime_root,
      i_signature
    );
    v_receipt_root := "gw_ledger".block_execute_signed_transaction(
      v_transaction_root,
      i_network,
      v_previous_state,
      v_previous_height + 1,
      i_timestamp
    );
    o_receipt := "gw_ledger".transaction_receipt_get(v_receipt_root);
    v_state_root := (o_receipt ->> 'state_root')::BYTEA;
    v_block_root := "gw_ledger".block_commit(
      i_network,
      v_previous_height,
      v_previous_state,
      v_previous_height + 1,
      (o_head ->> 'block_root')::BYTEA,
      v_previous_state,
      v_state_root,
      i_timestamp,
      "gw_ledger".admission_proposer_root(),
      null,
      jsonb_build_array(encode(v_transaction_root,'hex'))
    );
    o_bound := "gw_ledger".block_transaction_bind(v_block_root,0,v_receipt_root);
    RETURN jsonb_build_object(
      'address',
      encode(v_address_root,'hex'),
      'transaction_root',
      encode(v_transaction_root,'hex'),
      'receipt_root',
      encode(v_receipt_root,'hex'),
      'state_root',
      encode(v_state_root,'hex'),
      'block_root',
      encode(v_block_root,'hex'),
      'status',
      (o_receipt ->> 'status')::TEXT
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.admission/admission-submit-operation [190] 
CREATE OR REPLACE FUNCTION "gw_ledger".admission_submit_operation(
  i_network TEXT,
  i_public_key BYTEA,
  i_sequence BIGINT,
  i_op_root BYTEA,
  i_form_root BYTEA,
  i_cost_limit BIGINT,
  i_runtime_root BYTEA,
  i_signature BYTEA,
  i_timestamp BIGINT
) RETURNS JSONB AS $$

  DECLARE
    o_bound JSONB;
    o_head JSONB;
    o_receipt JSONB;
    v_account_root BYTEA;
    v_address_root BYTEA;
    v_block_root BYTEA;
    v_controller_root BYTEA;
    v_current_sequence BIGINT;
    v_expected_controller BYTEA;
    v_previous_height BIGINT;
    v_previous_state BYTEA;
    v_receipt_root BYTEA;
    v_state_root BYTEA;
    v_transaction_root BYTEA;
  BEGIN
    o_head := "gw_ledger".head_lock(i_network);
    IF NOT (o_head IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/network_missing','data',null))::TEXT,
        MESSAGE = 'ledger/network-missing'
      ;
    END IF;
    v_previous_state := (o_head ->> 'state_root')::BYTEA;
    v_previous_height := (o_head ->> 'height')::BIGINT;
    v_address_root := "gw_ledger".admission_address_root(i_public_key);
    v_account_root := "gw_ledger".state_account_root(v_previous_state,v_address_root);
    IF NOT (v_account_root IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_account','data',null))::TEXT,
        MESSAGE = 'ledger/missing-account'
      ;
    END IF;
    v_controller_root := "gw_ledger".account_value_controller_root(v_account_root);
    v_expected_controller := "gw_ledger".admission_controller_root(i_public_key);
    IF NOT (v_controller_root = v_expected_controller) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/controller_mismatch','data',null))::TEXT,
        MESSAGE = 'ledger/controller-mismatch'
      ;
    END IF;
    v_current_sequence := "gw_ledger".integer_bigint("gw_ledger".account_value_sequence_root(v_account_root));
    IF NOT (v_current_sequence = i_sequence) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/sequence_conflict','data',null))::TEXT,
        MESSAGE = 'ledger/sequence-conflict'
      ;
    END IF;
    IF NOT ("gw_ledger".op_valid(i_op_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_op','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-op'
      ;
    END IF;
    v_transaction_root := "gw_ledger".transaction_put(
      i_network,
      v_address_root,
      i_sequence,
      i_op_root,
      i_form_root,
      i_cost_limit,
      i_runtime_root,
      i_signature
    );
    v_receipt_root := "gw_ledger".block_execute_signed_transaction(
      v_transaction_root,
      i_network,
      v_previous_state,
      v_previous_height + 1,
      i_timestamp
    );
    o_receipt := "gw_ledger".transaction_receipt_get(v_receipt_root);
    v_state_root := (o_receipt ->> 'state_root')::BYTEA;
    v_block_root := "gw_ledger".block_commit(
      i_network,
      v_previous_height,
      v_previous_state,
      v_previous_height + 1,
      (o_head ->> 'block_root')::BYTEA,
      v_previous_state,
      v_state_root,
      i_timestamp,
      "gw_ledger".admission_proposer_root(),
      null,
      jsonb_build_array(encode(v_transaction_root,'hex'))
    );
    o_bound := "gw_ledger".block_transaction_bind(v_block_root,0,v_receipt_root);
    RETURN jsonb_build_object(
      'address',
      encode(v_address_root,'hex'),
      'transaction_root',
      encode(v_transaction_root,'hex'),
      'receipt_root',
      encode(v_receipt_root,'hex'),
      'result_root',
      encode((o_receipt ->> 'result_root')::BYTEA,'hex'),
      'cost_used',
      (o_receipt ->> 'cost_used')::BIGINT,
      'state_root',
      encode(v_state_root,'hex'),
      'block_root',
      encode(v_block_root,'hex'),
      'status',
      (o_receipt ->> 'status')::TEXT
    );
  END;

$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- gwdb.ledger.snapshot/Snapshot [18] 
DROP TABLE IF EXISTS "gw_ledger"."Snapshot" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."Snapshot" (
  "snapshot_root" BYTEA PRIMARY KEY,
  "state_root" BYTEA NOT NULL,
  "block_height" BIGINT NOT NULL,
  "codec_version" SMALLINT NOT NULL,
  "hash_algorithm" TEXT NOT NULL,
  "cell_count" BIGINT NOT NULL,
  "pack" BYTEA NOT NULL
);

-- gwdb.ledger.snapshot/snapshot-payload [29] 
CREATE OR REPLACE FUNCTION "gw_ledger".snapshot_payload(
  i_state_root BYTEA,
  i_block_height BIGINT,
  i_cell_count BIGINT,
  i_pack BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN decode(
    'R:snapshot:1:4:' || encode(i_state_root,'hex') || i_block_height || ':' || i_cell_count || ':' || encode(i_pack,'hex'),
    'escape'
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.snapshot/snapshot-get [42] 
CREATE OR REPLACE FUNCTION "gw_ledger".snapshot_get(
  i_snapshot_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT
        "snapshot_root",
        "state_root",
        "block_height",
        "codec_version",
        "hash_algorithm",
        "cell_count",
        "pack"
      FROM "gw_ledger"."Snapshot"
      WHERE "snapshot_root" = i_snapshot_root
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.snapshot/snapshot-root-seen-at [48] 
CREATE OR REPLACE FUNCTION "gw_ledger".snapshot_root_seen_at(
  i_roots JSONB,
  i_root BYTEA,
  i_position INTEGER,
  i_count INTEGER
) RETURNS BOOLEAN AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN false;
  ELSE
    DECLARE
    v_current BYTEA;
  BEGIN
    v_current := ((i_roots -> i_position) ->> 'child_hash')::BYTEA;
      IF v_current = i_root THEN
        RETURN true;
      ELSE
        RETURN "gw_ledger".snapshot_root_seen_at(i_roots,i_root,i_position + 1,i_count);
      END IF;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.snapshot/snapshot-root-tail [61] 
CREATE OR REPLACE FUNCTION "gw_ledger".snapshot_root_tail(
  i_roots JSONB,
  i_position INTEGER,
  i_count INTEGER,
  i_out JSONB
) RETURNS JSONB AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN i_out;
  ELSE
    DECLARE
    v_next JSONB;
      v_root JSONB;
  BEGIN
    v_root := (i_roots -> i_position);
      v_next := (i_out || jsonb_build_array(v_root));
      RETURN "gw_ledger".snapshot_root_tail(i_roots,i_position + 1,i_count,v_next);
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.snapshot/snapshot-reachable-roots-at [73] 
CREATE OR REPLACE FUNCTION "gw_ledger".snapshot_reachable_roots_at(
  i_pending JSONB,
  i_seen JSONB
) RETURNS JSONB AS $$

  DECLARE
    v_children JSONB;
    v_first JSONB;
    v_next_pending JSONB;
    v_next_seen JSONB;
    v_pending_count INTEGER;
    v_root BYTEA;
    v_seen BOOLEAN;
    v_seen_count INTEGER;
    v_tail JSONB;
  BEGIN
    v_pending_count := jsonb_array_length(i_pending);
    v_first := (i_pending -> 0);
    v_root := (v_first ->> 'child_hash')::BYTEA;
    v_seen_count := jsonb_array_length(i_seen);
    v_seen := "gw_ledger".snapshot_root_seen_at(i_seen,v_root,0,v_seen_count);
    v_tail := "gw_ledger".snapshot_root_tail(i_pending,1,v_pending_count,jsonb_build_array());
    v_children := "gw_ledger".cell_ref_children(v_root);
    v_next_pending := CASE WHEN v_seen THEN v_tail
    ELSE v_children || v_tail
    END;
    v_next_seen := CASE WHEN v_seen THEN i_seen
    ELSE i_seen || jsonb_build_array(v_first)
    END;
    IF v_pending_count = 0 THEN
      RETURN i_seen;
    ELSE
      RETURN "gw_ledger".snapshot_reachable_roots_at(v_next_pending,v_next_seen);
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.snapshot/snapshot-reachable-roots [97] 
CREATE OR REPLACE FUNCTION "gw_ledger".snapshot_reachable_roots(
  i_state_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    v_roots JSONB;
  BEGIN
    IF NOT ("gw_ledger".state_root_valid(i_state_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_snapshot_state',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-snapshot-state'
      ;
    END IF;
    v_roots := jsonb_build_array(jsonb_build_object('child_hash',i_state_root));
    RETURN "gw_ledger".snapshot_reachable_roots_at(v_roots,jsonb_build_array());
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.snapshot/snapshot-reachable-count [109] 
CREATE OR REPLACE FUNCTION "gw_ledger".snapshot_reachable_count(
  i_state_root BYTEA
) RETURNS BIGINT AS $$

  DECLARE
    v_roots JSONB;
  BEGIN
    v_roots := "gw_ledger".snapshot_reachable_roots(i_state_root);
    RETURN jsonb_array_length(v_roots);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.snapshot/snapshot-pack-ref-tail [117] 
CREATE OR REPLACE FUNCTION "gw_ledger".snapshot_pack_ref_tail(
  i_refs JSONB,
  i_position INTEGER,
  i_count INTEGER,
  i_out BYTEA
) RETURNS BYTEA AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN i_out;
  ELSE
    DECLARE
    v_child_root BYTEA;
      v_entry BYTEA;
      v_next BYTEA;
      v_ref JSONB;
      v_ref_position INTEGER;
      v_role TEXT;
  BEGIN
    v_ref := (i_refs -> i_position);
      v_ref_position := (v_ref ->> 'position')::INTEGER;
      v_role := (v_ref ->> 'role')::TEXT;
      v_child_root := (v_ref ->> 'child_hash')::BYTEA;
      v_entry := decode(
        'R:' || v_ref_position || ':' || encode(convert_to(v_role,'UTF8'),'hex') || ':' || encode(v_child_root,'hex') || ':',
        'escape'
      );
      v_next := (i_out || v_entry);
      RETURN "gw_ledger".snapshot_pack_ref_tail(i_refs,i_position + 1,i_count,v_next);
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.snapshot/snapshot-pack-cells-at [138] 
CREATE OR REPLACE FUNCTION "gw_ledger".snapshot_pack_cells_at(
  i_roots JSONB,
  i_position INTEGER,
  i_count INTEGER,
  i_out BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_cell JSONB;
    v_header BYTEA;
    v_ref_count INTEGER;
    v_refs JSONB;
    v_root BYTEA;
    v_root_entry JSONB;
    v_with_cell BYTEA;
    v_with_refs BYTEA;
  BEGIN
    v_root_entry := (i_roots -> i_position);
    v_root := (v_root_entry ->> 'child_hash')::BYTEA;
    o_cell := "gw_ledger".cell_by_hash(v_root);
    v_refs := "gw_ledger".cell_ref_entries(v_root);
    v_ref_count := jsonb_array_length(v_refs);
    v_header := decode(
      'C:' || encode(v_root,'hex') || ':' || (o_cell ->> 'codec_version')::SMALLINT || ':' || (o_cell ->> 'type_tag')::SMALLINT || ':' || encode((o_cell ->> 'payload')::BYTEA,'hex') || ':' || v_ref_count || ':',
      'escape'
    );
    v_with_cell := (i_out || v_header);
    v_with_refs := "gw_ledger".snapshot_pack_ref_tail(v_refs,0,v_ref_count,v_with_cell);
    IF i_position >= i_count THEN
      RETURN i_out;
    ELSE
      RETURN "gw_ledger".snapshot_pack_cells_at(i_roots,i_position + 1,i_count,v_with_refs);
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.snapshot/snapshot-pack [163] 
CREATE OR REPLACE FUNCTION "gw_ledger".snapshot_pack(
  i_state_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_count INTEGER;
    v_prefix BYTEA;
    v_roots JSONB;
  BEGIN
    v_roots := "gw_ledger".snapshot_reachable_roots(i_state_root);
    v_count := jsonb_array_length(v_roots);
    v_prefix := decode('HCP1:' || v_count || ':','escape');
    RETURN "gw_ledger".snapshot_pack_cells_at(v_roots,0,v_count,v_prefix);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.snapshot/snapshot-import-cells-at [173] 
CREATE OR REPLACE FUNCTION "gw_ledger".snapshot_import_cells_at(
  i_tokens JSONB,
  i_position INTEGER,
  i_count INTEGER
) RETURNS BOOLEAN AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN true;
  ELSE
    DECLARE
    v_codec INTEGER;
      v_inserted BYTEA;
      v_marker TEXT;
      v_payload BYTEA;
      v_ref_count INTEGER;
      v_root BYTEA;
      v_type_tag INTEGER;
  BEGIN
    v_marker := (i_tokens ->> i_position)::TEXT;
      v_root := decode((i_tokens ->> (i_position + 1))::TEXT,'hex');
      v_codec := (i_tokens ->> (i_position + 2))::INTEGER;
      v_type_tag := (i_tokens ->> (i_position + 3))::INTEGER;
      v_payload := decode((i_tokens ->> (i_position + 4))::TEXT,'hex');
      v_ref_count := (i_tokens ->> (i_position + 5))::INTEGER;
      IF NOT (v_marker = 'C') THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object(
            'status',
            'error',
            'tag',
            'ledger/invalid_snapshot_cell_marker',
            'data',
            null
          ))::TEXT,
          MESSAGE = 'ledger/invalid-snapshot-cell-marker'
        ;
      END IF;
      v_inserted := "gw_ledger".cell_put(v_root,v_codec,v_type_tag,v_payload);
      IF NOT (v_inserted = v_root) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object(
            'status',
            'error',
            'tag',
            'ledger/snapshot_cell_root_mismatch',
            'data',
            null
          ))::TEXT,
          MESSAGE = 'ledger/snapshot-cell-root-mismatch'
        ;
      END IF;
      RETURN "gw_ledger".snapshot_import_cells_at(i_tokens,i_position + 6 + (4 * v_ref_count),i_count);
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.snapshot/snapshot-import-ref-tail [199] 
CREATE OR REPLACE FUNCTION "gw_ledger".snapshot_import_ref_tail(
  i_parent_root BYTEA,
  i_tokens JSONB,
  i_position INTEGER,
  i_count INTEGER
) RETURNS BOOLEAN AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN true;
  ELSE
    DECLARE
    o_ref JSONB;
      v_child_root BYTEA;
      v_marker TEXT;
      v_ref_position INTEGER;
      v_role TEXT;
      v_role_hex TEXT;
  BEGIN
    v_marker := (i_tokens ->> i_position)::TEXT;
      v_ref_position := (i_tokens ->> (i_position + 1))::INTEGER;
      v_role_hex := (i_tokens ->> (i_position + 2))::TEXT;
      v_role := convert_from(decode(v_role_hex,'hex'),'UTF8');
      v_child_root := decode((i_tokens ->> (i_position + 3))::TEXT,'hex');
      IF NOT (v_marker = 'R') THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object(
            'status',
            'error',
            'tag',
            'ledger/invalid_snapshot_ref_marker',
            'data',
            null
          ))::TEXT,
          MESSAGE = 'ledger/invalid-snapshot-ref-marker'
        ;
      END IF;
      o_ref := "gw_ledger".cell_ref_put(i_parent_root,v_ref_position,v_role,v_child_root);
      RETURN "gw_ledger".snapshot_import_ref_tail(i_parent_root,i_tokens,i_position + 4,i_count);
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.snapshot/snapshot-import-refs-at [219] 
CREATE OR REPLACE FUNCTION "gw_ledger".snapshot_import_refs_at(
  i_tokens JSONB,
  i_position INTEGER,
  i_count INTEGER
) RETURNS BOOLEAN AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN true;
  ELSE
    DECLARE
    v_marker TEXT;
      v_ref_count INTEGER;
      v_refs BOOLEAN;
      v_root BYTEA;
  BEGIN
    v_marker := (i_tokens ->> i_position)::TEXT;
      v_root := decode((i_tokens ->> (i_position + 1))::TEXT,'hex');
      v_ref_count := (i_tokens ->> (i_position + 5))::INTEGER;
      IF NOT (v_marker = 'C') THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object(
            'status',
            'error',
            'tag',
            'ledger/invalid_snapshot_cell_marker',
            'data',
            null
          ))::TEXT,
          MESSAGE = 'ledger/invalid-snapshot-cell-marker'
        ;
      END IF;
      v_refs := "gw_ledger".snapshot_import_ref_tail(
        v_root,
        i_tokens,
        i_position + 6,
        i_position + 6 + (4 * v_ref_count)
      );
      RETURN "gw_ledger".snapshot_import_refs_at(i_tokens,i_position + 6 + (4 * v_ref_count),i_count);
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.snapshot/snapshot-pack-import [238] 
CREATE OR REPLACE FUNCTION "gw_ledger".snapshot_pack_import(
  i_pack BYTEA,
  i_cell_count BIGINT
) RETURNS BOOLEAN AS $$

  DECLARE
    v_cells BOOLEAN;
    v_declared_count BIGINT;
    v_header TEXT;
    v_last TEXT;
    v_refs BOOLEAN;
    v_token_count INTEGER;
    v_token_length INTEGER;
    v_tokens JSONB;
  BEGIN
    v_tokens := to_jsonb(string_to_array(encode(i_pack,'escape'),':'));
    v_token_length := jsonb_array_length(v_tokens);
    v_last := (v_tokens ->> (v_token_length - 1))::TEXT;
    v_token_count := CASE WHEN v_last = '' THEN v_token_length - 1
    ELSE v_token_length
    END;
    v_header := (v_tokens ->> 0)::TEXT;
    v_declared_count := (v_tokens ->> 1)::BIGINT;
    IF NOT ((v_header = 'HCP1') AND (v_declared_count = i_cell_count)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_snapshot_pack_header',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-snapshot-pack-header'
      ;
    END IF;
    v_cells := "gw_ledger".snapshot_import_cells_at(v_tokens,2,v_token_count);
    v_refs := "gw_ledger".snapshot_import_refs_at(v_tokens,2,v_token_count);
    RETURN v_cells AND v_refs;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.snapshot/snapshot-put [260] 
CREATE OR REPLACE FUNCTION "gw_ledger".snapshot_put(
  i_state_root BYTEA,
  i_block_height BIGINT,
  i_cell_count BIGINT,
  i_pack BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_state_ref JSONB;
    o_upsert JSONB;
    v_payload BYTEA;
    v_root BYTEA;
  BEGIN
    IF NOT ("gw_ledger".state_root_valid(i_state_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_snapshot_state',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-snapshot-state'
      ;
    END IF;
    IF NOT ((i_block_height >= 0) AND (i_cell_count >= 0)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_snapshot_bounds',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-snapshot-bounds'
      ;
    END IF;
    IF NOT (i_cell_count = "gw_ledger".snapshot_reachable_count(i_state_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/snapshot_cell_count_mismatch',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/snapshot-cell-count-mismatch'
      ;
    END IF;
    IF NOT (i_pack = "gw_ledger".snapshot_pack(i_state_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/snapshot_pack_mismatch',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/snapshot-pack-mismatch'
      ;
    END IF;
    v_payload := "gw_ledger".snapshot_payload(i_state_root,i_block_height,i_cell_count,i_pack);
    v_root := "gw_ledger".cell_put("gw_ledger".canonical_hash(14,v_payload),1,14,v_payload);
    o_state_ref := "gw_ledger".cell_ref_put(v_root,0,'state',i_state_root);
    WITH j_ret AS (  
      INSERT INTO "gw_ledger"."Snapshot" (
        "snapshot_root",
        "state_root",
        "block_height",
        "codec_version",
        "hash_algorithm",
        "cell_count",
        "pack"
      ) VALUES (
        (v_root)::BYTEA,
        (i_state_root)::BYTEA,
        (i_block_height)::BIGINT,
        (1)::SMALLINT,
        ('sha256')::TEXT,
        (i_cell_count)::BIGINT,
        (i_pack)::BYTEA
      ) ON CONFLICT ("snapshot_root") DO UPDATE SET ("snapshot_root",
        "state_root",
        "block_height",
        "codec_version",
        "hash_algorithm",
        "cell_count",
        "pack") = row(
        EXCLUDED."snapshot_root",
        EXCLUDED."state_root",
        EXCLUDED."block_height",
        EXCLUDED."codec_version",
        EXCLUDED."hash_algorithm",
        EXCLUDED."cell_count",
        EXCLUDED."pack"
      ) RETURNING
        "snapshot_root",
        "state_root",
        "block_height",
        "codec_version",
        "hash_algorithm",
        "cell_count",
        "pack")
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_upsert;
    RETURN v_root;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.snapshot/snapshot-create [284] 
CREATE OR REPLACE FUNCTION "gw_ledger".snapshot_create(
  i_state_root BYTEA,
  i_block_height BIGINT
) RETURNS BYTEA AS $$

  DECLARE
    v_count BIGINT;
    v_pack BYTEA;
  BEGIN
    v_count := "gw_ledger".snapshot_reachable_count(i_state_root);
    v_pack := "gw_ledger".snapshot_pack(i_state_root);
    RETURN "gw_ledger".snapshot_put(i_state_root,i_block_height,v_count,v_pack);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.snapshot/snapshot-valid [293] 
CREATE OR REPLACE FUNCTION "gw_ledger".snapshot_valid(
  i_snapshot_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_cell JSONB;
    o_snapshot JSONB;
    v_payload BYTEA;
  BEGIN
    o_snapshot := "gw_ledger".snapshot_get(i_snapshot_root);
    o_cell := "gw_ledger".cell_by_hash(i_snapshot_root);
    IF o_snapshot IS NULL OR o_cell IS NULL THEN
      RETURN false;
    END IF;
    v_payload := "gw_ledger".snapshot_payload(
      (o_snapshot ->> 'state_root')::BYTEA,
      (o_snapshot ->> 'block_height')::BIGINT,
      (o_snapshot ->> 'cell_count')::BIGINT,
      (o_snapshot ->> 'pack')::BYTEA
    );
    RETURN ((o_snapshot ->> 'codec_version')::SMALLINT = 1) AND ((o_snapshot ->> 'hash_algorithm')::TEXT = 'sha256') AND "gw_ledger".state_root_valid((o_snapshot ->> 'state_root')::BYTEA) AND ((o_snapshot ->> 'cell_count')::BIGINT = "gw_ledger".snapshot_reachable_count((o_snapshot ->> 'state_root')::BYTEA)) AND ((o_snapshot ->> 'pack')::BYTEA = "gw_ledger".snapshot_pack((o_snapshot ->> 'state_root')::BYTEA)) AND ((o_cell ->> 'type_tag')::SMALLINT = 14) AND ((o_cell ->> 'payload')::BYTEA = v_payload) AND "gw_ledger".verify(i_snapshot_root,14,v_payload) AND ("gw_ledger".cell_ref_count(i_snapshot_root,'state') = 1);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.snapshot/snapshot-export [320] 
CREATE OR REPLACE FUNCTION "gw_ledger".snapshot_export(
  i_snapshot_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_snapshot JSONB;
  BEGIN
    o_snapshot := "gw_ledger".snapshot_get(i_snapshot_root);
    IF NOT ("gw_ledger".snapshot_valid(i_snapshot_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_snapshot','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-snapshot'
      ;
    END IF;
    RETURN jsonb_build_object(
      'snapshot/root',
      encode(i_snapshot_root,'hex'),
      'state/root',
      encode((o_snapshot ->> 'state_root')::BYTEA,'hex'),
      'block/height',
      (o_snapshot ->> 'block_height')::BIGINT,
      'codec/version',
      1,
      'hash/algorithm',
      'sha256',
      'cell/count',
      (o_snapshot ->> 'cell_count')::BIGINT,
      'pack',
      encode((o_snapshot ->> 'pack')::BYTEA,'hex')
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.snapshot/snapshot-import [336] 
CREATE OR REPLACE FUNCTION "gw_ledger".snapshot_import(
  i_export JSONB
) RETURNS BYTEA AS $$

  DECLARE
    o_state JSONB;
    v_count BIGINT;
    v_height BIGINT;
    v_imported BYTEA;
    v_pack BYTEA;
    v_restored BOOLEAN;
    v_root BYTEA;
    v_state_root BYTEA;
  BEGIN
    v_root := decode((i_export ->> 'snapshot/root')::TEXT,'hex');
    v_state_root := decode((i_export ->> 'state/root')::TEXT,'hex');
    v_height := (i_export ->> 'block/height')::BIGINT;
    v_count := (i_export ->> 'cell/count')::BIGINT;
    v_pack := decode((i_export ->> 'pack')::TEXT,'hex');
    IF NOT (((i_export ->> 'codec/version')::INTEGER = 1) AND ((i_export ->> 'hash/algorithm')::TEXT = 'sha256')) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/unsupported_snapshot_export',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/unsupported-snapshot-export'
      ;
    END IF;
    v_restored := "gw_ledger".snapshot_pack_import(v_pack,v_count);
    IF NOT (v_restored) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/snapshot_pack_import_failed',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/snapshot-pack-import-failed'
      ;
    END IF;
    o_state := "gw_ledger".state_rebuild_head(v_state_root,v_height);
    v_imported := "gw_ledger".snapshot_put(v_state_root,v_height,v_count,v_pack);
    IF NOT (v_imported = v_root) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/snapshot_import_mismatch',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/snapshot-import-mismatch'
      ;
    END IF;
    RETURN v_imported;
  END;

$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- gwdb.ledger.iterator/IteratorPlan [18] 
DROP TABLE IF EXISTS "gw_ledger"."IteratorPlan" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."IteratorPlan" (
  "plan_root" BYTEA PRIMARY KEY,
  "plan_version" SMALLINT NOT NULL,
  "plan_type" TEXT NOT NULL,
  "function_root" BYTEA
);

-- gwdb.ledger.iterator/Iterator [26] 
DROP TABLE IF EXISTS "gw_ledger"."Iterator" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."Iterator" (
  "iterator_root" BYTEA PRIMARY KEY,
  "iterator_version" SMALLINT NOT NULL,
  "iterator_type" TEXT NOT NULL,
  "plan_root" BYTEA NOT NULL,
  "source_root" BYTEA NOT NULL,
  "state_root" BYTEA NOT NULL
);

-- gwdb.ledger.iterator/plan-type-valid [36] 
CREATE OR REPLACE FUNCTION "gw_ledger".plan_type_valid(
  i_plan_type TEXT
) RETURNS BOOLEAN AS $$

  SELECT (i_plan_type = 'vector') OR (i_plan_type = 'map') OR (i_plan_type = 'filter') OR (i_plan_type = 'take') OR (i_plan_type = 'drop');

$$ LANGUAGE 'sql' IMMUTABLE PARALLEL SAFE;

-- gwdb.ledger.iterator/iterator-root-hex [48] 
CREATE OR REPLACE FUNCTION "gw_ledger".iterator_root_hex(
  i_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN CASE WHEN i_root IS NULL THEN '-'
  ELSE encode(i_root,'hex')
  END;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.iterator/plan-payload [54] 
CREATE OR REPLACE FUNCTION "gw_ledger".plan_payload(
  i_plan_type TEXT,
  i_function_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN decode(
    'R:iterator-plan:1:' || i_plan_type || ':' || "gw_ledger".iterator_root_hex(i_function_root),
    'escape'
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.iterator/plan-put [62] 
CREATE OR REPLACE FUNCTION "gw_ledger".plan_put(
  i_plan_type TEXT,
  i_function_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_function JSONB;
    o_function_ref JSONB;
    o_upsert JSONB;
    v_payload BYTEA;
    v_root BYTEA;
  BEGIN
    IF NOT ("gw_ledger".plan_type_valid(i_plan_type)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/unknown_iterator_plan',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/unknown-iterator-plan'
      ;
    END IF;
    o_function := "gw_ledger".cell_by_hash(i_function_root);
    IF NOT (i_function_root IS NULL OR o_function IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_iterator_function',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-iterator-function'
      ;
    END IF;
    v_payload := "gw_ledger".plan_payload(i_plan_type,i_function_root);
    v_root := "gw_ledger".cell_put("gw_ledger".canonical_hash(19,v_payload),1,19,v_payload);
    o_function_ref := CASE WHEN i_function_root IS NULL THEN null
    ELSE "gw_ledger".cell_ref_put(v_root,0,'function',i_function_root)
    END;
    WITH j_ret AS (  
      INSERT INTO "gw_ledger"."IteratorPlan" ("plan_root","plan_version","plan_type","function_root") VALUES (
        (v_root)::BYTEA,
        (1)::SMALLINT,
        (i_plan_type)::TEXT,
        (i_function_root)::BYTEA
      ) ON CONFLICT ("plan_root") DO UPDATE SET ("plan_root","plan_version","plan_type","function_root") = row(
        EXCLUDED."plan_root",
        EXCLUDED."plan_version",
        EXCLUDED."plan_type",
        EXCLUDED."function_root"
      ) RETURNING "plan_root","plan_version","plan_type","function_root")
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_upsert;
    RETURN v_root;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.iterator/plan-get [83] 
CREATE OR REPLACE FUNCTION "gw_ledger".plan_get(
  i_plan_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT "plan_root","plan_version","plan_type","function_root" FROM "gw_ledger"."IteratorPlan"
      WHERE "plan_root" = i_plan_root
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.iterator/plan-valid [89] 
CREATE OR REPLACE FUNCTION "gw_ledger".plan_valid(
  i_plan_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_cell JSONB;
    o_plan JSONB;
    v_payload BYTEA;
  BEGIN
    o_cell := "gw_ledger".cell_by_hash(i_plan_root);
    o_plan := "gw_ledger".plan_get(i_plan_root);
    IF o_cell IS NULL OR o_plan IS NULL THEN
      RETURN false;
    END IF;
    v_payload := "gw_ledger".plan_payload(
      (o_plan ->> 'plan_type')::TEXT,
      (o_plan ->> 'function_root')::BYTEA
    );
    RETURN ((o_cell ->> 'type_tag')::SMALLINT = 19) AND "gw_ledger".plan_type_valid((o_plan ->> 'plan_type')::TEXT) AND ((o_cell ->> 'payload')::BYTEA = v_payload) AND "gw_ledger".verify(i_plan_root,19,v_payload);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.iterator/iterator-payload [103] 
CREATE OR REPLACE FUNCTION "gw_ledger".iterator_payload(
  i_iterator_type TEXT,
  i_plan_root BYTEA,
  i_source_root BYTEA,
  i_state_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN decode(
    'R:iterator:1:' || i_iterator_type || ':' || "gw_ledger".iterator_root_hex(i_plan_root) || "gw_ledger".iterator_root_hex(i_source_root) || "gw_ledger".iterator_root_hex(i_state_root),
    'escape'
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.iterator/iterator-attach [113] 
CREATE OR REPLACE FUNCTION "gw_ledger".iterator_attach(
  i_iterator_type TEXT,
  i_plan_root BYTEA,
  i_source_root BYTEA,
  i_state_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_plan JSONB;
    o_plan_ref JSONB;
    o_source JSONB;
    o_source_ref JSONB;
    o_state JSONB;
    o_state_ref JSONB;
    o_upsert JSONB;
    v_payload BYTEA;
    v_root BYTEA;
  BEGIN
    o_plan := "gw_ledger".plan_get(i_plan_root);
    o_source := "gw_ledger".cell_by_hash(i_source_root);
    o_state := "gw_ledger".cell_by_hash(i_state_root);
    IF NOT ("gw_ledger".plan_valid(i_plan_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_iterator_plan',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-iterator-plan'
      ;
    END IF;
    IF NOT (o_source IS NOT NULL AND ((o_source ->> 'type_tag')::SMALLINT = 10)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/vector_iterator_requires_vector',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/vector-iterator-requires-vector'
      ;
    END IF;
    IF NOT (o_state IS NOT NULL AND ((o_state ->> 'type_tag')::SMALLINT = 2)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/iterator_state_not_integer',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/iterator-state-not-integer'
      ;
    END IF;
    IF NOT ((i_iterator_type = 'vector') AND ((o_plan ->> 'plan_type')::TEXT = 'vector')) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_iterator_attachment',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-iterator-attachment'
      ;
    END IF;
    v_payload := "gw_ledger".iterator_payload(i_iterator_type,i_plan_root,i_source_root,i_state_root);
    v_root := "gw_ledger".cell_put("gw_ledger".canonical_hash(20,v_payload),1,20,v_payload);
    o_plan_ref := "gw_ledger".cell_ref_put(v_root,0,'plan',i_plan_root);
    o_source_ref := "gw_ledger".cell_ref_put(v_root,1,'source',i_source_root);
    o_state_ref := "gw_ledger".cell_ref_put(v_root,2,'state',i_state_root);
    WITH j_ret AS (  
      INSERT INTO "gw_ledger"."Iterator" (
        "iterator_root",
        "iterator_version",
        "iterator_type",
        "plan_root",
        "source_root",
        "state_root"
      ) VALUES (
        (v_root)::BYTEA,
        (1)::SMALLINT,
        (i_iterator_type)::TEXT,
        (i_plan_root)::BYTEA,
        (i_source_root)::BYTEA,
        (i_state_root)::BYTEA
      ) ON CONFLICT ("iterator_root") DO UPDATE SET ("iterator_root",
        "iterator_version",
        "iterator_type",
        "plan_root",
        "source_root",
        "state_root") = row(
        EXCLUDED."iterator_root",
        EXCLUDED."iterator_version",
        EXCLUDED."iterator_type",
        EXCLUDED."plan_root",
        EXCLUDED."source_root",
        EXCLUDED."state_root"
      ) RETURNING
        "iterator_root",
        "iterator_version",
        "iterator_type",
        "plan_root",
        "source_root",
        "state_root")
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_upsert;
    RETURN v_root;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.iterator/iterator-get [143] 
CREATE OR REPLACE FUNCTION "gw_ledger".iterator_get(
  i_iterator_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT
        "iterator_root",
        "iterator_version",
        "iterator_type",
        "plan_root",
        "source_root",
        "state_root"
      FROM "gw_ledger"."Iterator"
      WHERE "iterator_root" = i_iterator_root
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN o_row;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.iterator/iterator-valid [149] 
CREATE OR REPLACE FUNCTION "gw_ledger".iterator_valid(
  i_iterator_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_cell JSONB;
    o_iterator JSONB;
    v_payload BYTEA;
  BEGIN
    o_cell := "gw_ledger".cell_by_hash(i_iterator_root);
    o_iterator := "gw_ledger".iterator_get(i_iterator_root);
    IF o_cell IS NULL OR o_iterator IS NULL THEN
      RETURN false;
    END IF;
    v_payload := "gw_ledger".iterator_payload(
      (o_iterator ->> 'iterator_type')::TEXT,
      (o_iterator ->> 'plan_root')::BYTEA,
      (o_iterator ->> 'source_root')::BYTEA,
      (o_iterator ->> 'state_root')::BYTEA
    );
    RETURN ((o_cell ->> 'type_tag')::SMALLINT = 20) AND ((o_cell ->> 'payload')::BYTEA = v_payload) AND "gw_ledger".verify(i_iterator_root,20,v_payload) AND ("gw_ledger".cell_ref_count(i_iterator_root,'plan') = 1) AND ("gw_ledger".cell_ref_count(i_iterator_root,'source') = 1) AND ("gw_ledger".cell_ref_count(i_iterator_root,'state') = 1);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.iterator/iterator-step-active [168] 
CREATE OR REPLACE FUNCTION "gw_ledger".iterator_step_active(
  i_plan_root BYTEA,
  i_source_root BYTEA,
  i_position BIGINT,
  i_value_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    v_next_root BYTEA;
    v_next_state BYTEA;
  BEGIN
    v_next_state := "gw_ledger".put_integer_number(i_position + 1);
    v_next_root := "gw_ledger".iterator_attach('vector',i_plan_root,i_source_root,v_next_state);
    RETURN jsonb_build_object('done',false,'value',i_value_root,'next',v_next_root,'cost_used',1);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.iterator/iterator-step [179] 
CREATE OR REPLACE FUNCTION "gw_ledger".iterator_step(
  i_iterator_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_iterator JSONB;
    v_position BIGINT;
    v_source_root BYTEA;
    v_value_root BYTEA;
  BEGIN
    o_iterator := "gw_ledger".iterator_get(i_iterator_root);
    IF o_iterator is null  THEN
      RETURN jsonb_build_object('done',true,'next',null,'cost_used',1);
    END IF;
    IF NOT "gw_ledger".iterator_valid(i_iterator_root) THEN
      RETURN jsonb_build_object('done',true,'next',null,'cost_used',1);
    END IF;
    v_source_root := (o_iterator ->> 'source_root')::BYTEA;
    v_position := "gw_ledger".integer_bigint((o_iterator ->> 'state_root')::BYTEA);
    v_value_root := "gw_ledger".vector_get(v_source_root,(v_position)::INTEGER);
    IF v_value_root is null  THEN
      RETURN jsonb_build_object('done',true,'next',null,'cost_used',1);
    ELSE
      RETURN "gw_ledger".iterator_step_active(
        (o_iterator ->> 'plan_root')::BYTEA,
        v_source_root,
        v_position,
        v_value_root
      );
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

CREATE SCHEMA IF NOT EXISTS "gw_ledger";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";