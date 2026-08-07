

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

-- gwdb.ledger.account/Definition [32] 
DROP TABLE IF EXISTS "gw_ledger"."Definition" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."Definition" (
  "address" BYTEA,
  "symbol_root" BYTEA,
  "value_root" BYTEA NOT NULL,
  "state_root" BYTEA NOT NULL,
  "created_at" BIGINT NOT NULL DEFAULT (1000000 * extract(epoch FROM now()))::BIGINT,
  PRIMARY KEY (address,symbol_root)
);

-- gwdb.ledger.account/account-value-payload [42] 
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

-- gwdb.ledger.account/account-value-put [58] 
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

-- gwdb.ledger.account/account-value-v2-payload [91] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_v2_payload(
  i_sequence_root BYTEA,
  i_environment_root BYTEA,
  i_metadata_root BYTEA,
  i_key_root BYTEA,
  i_controller_root BYTEA,
  i_parent_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN decode(
    'R:account:2:6:' || encode(i_sequence_root,'hex') || encode(i_environment_root,'hex') || encode(i_metadata_root,'hex') || encode(i_key_root,'hex') || encode(i_controller_root,'hex') || encode(i_parent_root,'hex'),
    'escape'
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-v2-put [112] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_v2_put(
  i_sequence_root BYTEA,
  i_environment_root BYTEA,
  i_metadata_root BYTEA,
  i_key_root BYTEA,
  i_controller_root BYTEA,
  i_parent_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_controller JSONB;
    o_controller_ref JSONB;
    o_environment JSONB;
    o_environment_ref JSONB;
    o_key JSONB;
    o_key_ref JSONB;
    o_metadata JSONB;
    o_metadata_ref JSONB;
    o_parent JSONB;
    o_parent_ref JSONB;
    o_sequence JSONB;
    o_sequence_ref JSONB;
    v_payload BYTEA;
    v_root BYTEA;
  BEGIN
    o_sequence := "gw_ledger".cell_by_hash(i_sequence_root);
    o_environment := "gw_ledger".cell_by_hash(i_environment_root);
    o_metadata := "gw_ledger".cell_by_hash(i_metadata_root);
    o_key := "gw_ledger".cell_by_hash(i_key_root);
    o_controller := "gw_ledger".cell_by_hash(i_controller_root);
    o_parent := "gw_ledger".cell_by_hash(i_parent_root);
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
    IF NOT (o_key IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_account_key','data',null))::TEXT,
        MESSAGE = 'ledger/missing-account-key'
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
    IF NOT (o_parent IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_account_parent',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-account-parent'
      ;
    END IF;
    v_payload := "gw_ledger".account_value_v2_payload(
      i_sequence_root,
      i_environment_root,
      i_metadata_root,
      i_key_root,
      i_controller_root,
      i_parent_root
    );
    v_root := "gw_ledger".cell_put("gw_ledger".canonical_hash(14,v_payload),1,14,v_payload);
    o_sequence_ref := "gw_ledger".cell_ref_put(v_root,0,'sequence',i_sequence_root);
    o_environment_ref := "gw_ledger".cell_ref_put(v_root,1,'environment',i_environment_root);
    o_metadata_ref := "gw_ledger".cell_ref_put(v_root,2,'metadata',i_metadata_root);
    o_key_ref := "gw_ledger".cell_ref_put(v_root,3,'key',i_key_root);
    o_controller_ref := "gw_ledger".cell_ref_put(v_root,4,'controller',i_controller_root);
    o_parent_ref := "gw_ledger".cell_ref_put(v_root,5,'parent',i_parent_root);
    RETURN v_root;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-create-v1 [155] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_create_v1(
  i_controller_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".account_value_put(
    "gw_ledger".put_integer('0'),
    "gw_ledger".put_map(jsonb_build_array()),
    "gw_ledger".put_map(jsonb_build_array()),
    i_controller_root
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-create [167] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_create(
  i_key_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_nil BYTEA;
  BEGIN
    v_nil := "gw_ledger".put_nil();
    RETURN "gw_ledger".account_value_v2_put(
      "gw_ledger".put_integer('0'),
      "gw_ledger".put_map(jsonb_build_array()),
      "gw_ledger".put_map(jsonb_build_array()),
      i_key_root,
      v_nil,
      v_nil
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-create-external [179] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_create_external(
  i_key_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".account_value_create(i_key_root);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-create-actor [186] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_create_actor(
  i_controller_root BYTEA,
  i_parent_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".account_value_v2_put(
    "gw_ledger".put_integer('0'),
    "gw_ledger".put_map(jsonb_build_array()),
    "gw_ledger".put_map(jsonb_build_array()),
    "gw_ledger".put_nil(),
    i_controller_root,
    i_parent_root
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-version [198] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_version(
  i_account_root BYTEA
) RETURNS INTEGER AS $$
BEGIN
  RETURN CASE WHEN "gw_ledger".cell_ref_count(i_account_root,'key') = 1 THEN 2
  ELSE 1
  END;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-sequence-root [207] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_sequence_root(
  i_account_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_ref_child(i_account_root,0,'sequence');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-environment-root [212] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_environment_root(
  i_account_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_ref_child(i_account_root,1,'environment');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-metadata-root [217] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_metadata_root(
  i_account_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".cell_ref_child(i_account_root,2,'metadata');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-key-root [222] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_key_root(
  i_account_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN CASE WHEN "gw_ledger".account_value_version(i_account_root) = 2 THEN "gw_ledger".cell_ref_child(i_account_root,3,'key')
  ELSE "gw_ledger".cell_ref_child(i_account_root,3,'controller')
  END;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-authority-root [233] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_authority_root(
  i_account_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN CASE WHEN "gw_ledger".account_value_version(i_account_root) = 2 THEN "gw_ledger".cell_ref_child(i_account_root,4,'controller')
  ELSE "gw_ledger".put_nil()
  END;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-controller-root [243] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_controller_root(
  i_account_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".account_value_key_root(i_account_root);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-parent-root [249] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_parent_root(
  i_account_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN CASE WHEN "gw_ledger".account_value_version(i_account_root) = 2 THEN "gw_ledger".cell_ref_child(i_account_root,5,'parent')
  ELSE "gw_ledger".put_nil()
  END;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-rebuild [258] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_rebuild(
  i_account_root BYTEA,
  i_sequence_root BYTEA,
  i_environment_root BYTEA,
  i_metadata_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN CASE WHEN "gw_ledger".account_value_version(i_account_root) = 2 THEN "gw_ledger".account_value_v2_put(
    i_sequence_root,
    i_environment_root,
    i_metadata_root,
    "gw_ledger".account_value_key_root(i_account_root),
    "gw_ledger".account_value_authority_root(i_account_root),
    "gw_ledger".account_value_parent_root(i_account_root)
  )
  ELSE "gw_ledger".account_value_put(
    i_sequence_root,
    i_environment_root,
    i_metadata_root,
    "gw_ledger".account_value_key_root(i_account_root)
  )
  END;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-define-empty [278] 
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
    RETURN "gw_ledger".account_value_rebuild(
      i_account_root,
      "gw_ledger".account_value_sequence_root(i_account_root),
      v_next_environment,
      "gw_ledger".account_value_metadata_root(i_account_root)
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-define [292] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_define(
  i_account_root BYTEA,
  i_symbol_root BYTEA,
  i_value_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".account_value_define_empty(i_account_root,i_symbol_root,i_value_root);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-set-definition-metadata [298] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_set_definition_metadata(
  i_account_root BYTEA,
  i_symbol_root BYTEA,
  i_definition_metadata_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_metadata JSONB;
    v_next_metadata BYTEA;
  BEGIN
    o_metadata := "gw_ledger".cell_by_hash(i_definition_metadata_root);
    IF NOT (o_metadata IS NOT NULL AND ((o_metadata ->> 'type_tag')::SMALLINT = 11)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/definition_metadata_not_map',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/definition-metadata-not-map'
      ;
    END IF;
    v_next_metadata := "gw_ledger".map_assoc(
      "gw_ledger".account_value_metadata_root(i_account_root),
      i_symbol_root,
      i_definition_metadata_root
    );
    RETURN "gw_ledger".account_value_rebuild(
      i_account_root,
      "gw_ledger".account_value_sequence_root(i_account_root),
      "gw_ledger".account_value_environment_root(i_account_root),
      v_next_metadata
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-define-with-metadata [318] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_define_with_metadata(
  i_account_root BYTEA,
  i_symbol_root BYTEA,
  i_value_root BYTEA,
  i_definition_metadata_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".account_value_set_definition_metadata(
    "gw_ledger".account_value_define(i_account_root,i_symbol_root,i_value_root),
    i_symbol_root,
    i_definition_metadata_root
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-definition-metadata [329] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_definition_metadata(
  i_account_root BYTEA,
  i_symbol_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".map_get(
    "gw_ledger".account_value_metadata_root(i_account_root),
    i_symbol_root
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-set-key [337] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_set_key(
  i_account_root BYTEA,
  i_key_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".account_value_v2_put(
    "gw_ledger".account_value_sequence_root(i_account_root),
    "gw_ledger".account_value_environment_root(i_account_root),
    "gw_ledger".account_value_metadata_root(i_account_root),
    i_key_root,
    "gw_ledger".account_value_authority_root(i_account_root),
    "gw_ledger".account_value_parent_root(i_account_root)
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-set-controller [351] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_value_set_controller(
  i_account_root BYTEA,
  i_controller_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".account_value_v2_put(
    "gw_ledger".account_value_sequence_root(i_account_root),
    "gw_ledger".account_value_environment_root(i_account_root),
    "gw_ledger".account_value_metadata_root(i_account_root),
    "gw_ledger".account_value_key_root(i_account_root),
    i_controller_root,
    "gw_ledger".account_value_parent_root(i_account_root)
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-advance-sequence [365] 
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
    RETURN "gw_ledger".account_value_rebuild(
      i_account_root,
      v_next_sequence,
      "gw_ledger".account_value_environment_root(i_account_root),
      "gw_ledger".account_value_metadata_root(i_account_root)
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-value-lookup [378] 
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

-- gwdb.ledger.account/account-get [385] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_get(
  i_address BYTEA
) RETURNS JSONB AS $$
BEGIN
  RETURN WITH j_ret AS (  
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
  SELECT to_jsonb(j_ret) FROM j_ret;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-put [391] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_put(
  i_address BYTEA,
  i_sequence BIGINT,
  i_state_root BYTEA,
  i_environment_root BYTEA,
  i_metadata_root BYTEA,
  i_controller BYTEA
) RETURNS JSONB AS $$
BEGIN
  RETURN WITH j_ret AS (  
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
  SELECT to_jsonb(j_ret) FROM j_ret;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-sequence [410] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_sequence(
  i_address BYTEA
) RETURNS BIGINT AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    o_row := "gw_ledger".account_get(i_address);
    RETURN CASE WHEN o_row IS NOT NULL THEN (o_row ->> 'sequence')::BIGINT
    ELSE 0
    END;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-environment [420] 
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

-- gwdb.ledger.account/account-metadata [427] 
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

-- gwdb.ledger.account/account-lookup [434] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_lookup(
  i_address BYTEA
) RETURNS JSONB AS $$
BEGIN
  RETURN "gw_ledger".account_get(i_address);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-create [440] 
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

-- gwdb.ledger.account/account-define [451] 
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

-- gwdb.ledger.account/account-set-metadata [463] 
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

-- gwdb.ledger.account/definition-put [475] 
CREATE OR REPLACE FUNCTION "gw_ledger".definition_put(
  i_address BYTEA,
  i_symbol_root BYTEA,
  i_value_root BYTEA,
  i_state_root BYTEA
) RETURNS JSONB AS $$
BEGIN
  RETURN WITH j_ret AS (  
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
  SELECT to_jsonb(j_ret) FROM j_ret;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/definition-get [489] 
CREATE OR REPLACE FUNCTION "gw_ledger".definition_get(
  i_address BYTEA,
  i_symbol_root BYTEA
) RETURNS JSONB AS $$
BEGIN
  RETURN WITH j_ret AS (  
    SELECT "address","symbol_root","value_root","state_root","created_at" FROM "gw_ledger"."Definition"
    WHERE "address" = i_address AND "symbol_root" = i_symbol_root
    LIMIT 1)
  SELECT to_jsonb(j_ret) FROM j_ret;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account/account-advance-sequence [498] 
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

-- gwdb.ledger.protocol/result-ok [23] 
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

-- gwdb.ledger.protocol/result-error [33] 
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

-- gwdb.ledger.protocol/keyword-root [46] 
CREATE OR REPLACE FUNCTION "gw_ledger".keyword_root(
  i_name TEXT
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_keyword(i_name);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/record-field [52] 
CREATE OR REPLACE FUNCTION "gw_ledger".record_field(
  i_record_root BYTEA,
  i_field TEXT
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".map_get(i_record_root,"gw_ledger".keyword_root(i_field));
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/record-start [58] 
CREATE OR REPLACE FUNCTION "gw_ledger".record_start(
  i_kind TEXT
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".map_assoc(
    "gw_ledger".put_map(jsonb_build_array()),
    "gw_ledger".keyword_root('record/type'),
    "gw_ledger".keyword_root(i_kind)
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/record-assoc [68] 
CREATE OR REPLACE FUNCTION "gw_ledger".record_assoc(
  i_record_root BYTEA,
  i_field TEXT,
  i_value_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".map_assoc(i_record_root,"gw_ledger".keyword_root(i_field),i_value_root);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/record-kind [75] 
CREATE OR REPLACE FUNCTION "gw_ledger".record_kind(
  i_record_root BYTEA,
  i_kind TEXT
) RETURNS BOOLEAN AS $$

  DECLARE
    o_cell JSONB;
    v_kind_root BYTEA;
  BEGIN
    o_cell := "gw_ledger".cell_by_hash(i_record_root);
    IF o_cell IS NULL OR NOT ((o_cell ->> 'type_tag')::SMALLINT = 11) THEN
      RETURN false;
    END IF;
    v_kind_root := "gw_ledger".record_field(i_record_root,'record/type');
    RETURN v_kind_root = "gw_ledger".keyword_root(i_kind);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/protocol-methods-valid-at [86] 
CREATE OR REPLACE FUNCTION "gw_ledger".protocol_methods_valid_at(
  i_methods_root BYTEA,
  i_position INTEGER,
  i_count INTEGER
) RETURNS BOOLEAN AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN true;
  ELSE
    DECLARE
    o_arity JSONB;
      o_name JSONB;
      v_arity_root BYTEA;
      v_name TEXT;
      v_name_root BYTEA;
  BEGIN
    v_name_root := "gw_ledger".cell_ref_child(i_methods_root,i_position,'key');
      v_arity_root := "gw_ledger".cell_ref_child(i_methods_root,i_position,'value');
      o_name := "gw_ledger".cell_by_hash(v_name_root);
      o_arity := "gw_ledger".cell_by_hash(v_arity_root);
      v_name := CASE WHEN o_name IS NULL THEN ''
      ELSE encode((o_name ->> 'payload')::BYTEA,'escape')
      END;
      IF o_name IS NULL OR o_arity IS NULL OR NOT ((o_name ->> 'type_tag')::SMALLINT = 7) OR NOT ((o_arity ->> 'type_tag')::SMALLINT = 2) OR regexp_match(v_name,'!$') IS NOT NULL OR ("gw_ledger".integer_bigint(v_arity_root) < 1) THEN
        RETURN false;
      ELSE
        RETURN "gw_ledger".protocol_methods_valid_at(i_methods_root,i_position + 1,i_count);
      END IF;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/protocol-methods-valid [113] 
CREATE OR REPLACE FUNCTION "gw_ledger".protocol_methods_valid(
  i_methods_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_methods JSONB;
  BEGIN
    o_methods := "gw_ledger".cell_by_hash(i_methods_root);
    RETURN o_methods IS NOT NULL AND ((o_methods ->> 'type_tag')::SMALLINT = 11) AND "gw_ledger".protocol_methods_valid_at(
      i_methods_root,
      0,
      "gw_ledger".cell_ref_count(i_methods_root,'key')
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/protocol-put [124] 
CREATE OR REPLACE FUNCTION "gw_ledger".protocol_put(
  i_name_root BYTEA,
  i_methods_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_complete BYTEA;
    v_named BYTEA;
    v_record BYTEA;
  BEGIN
    IF NOT ("gw_ledger".cell_type_tag(i_name_root) = 7) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/protocol_name_not_symbol',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/protocol-name-not-symbol'
      ;
    END IF;
    IF NOT ("gw_ledger".protocol_methods_valid(i_methods_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_protocol_methods',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-protocol-methods'
      ;
    END IF;
    v_record := "gw_ledger".record_start('protocol');
    v_named := "gw_ledger".record_assoc(v_record,'protocol/name',i_name_root);
    v_complete := "gw_ledger".record_assoc(v_named,'protocol/methods',i_methods_root);
    RETURN v_complete;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/protocol-valid [139] 
CREATE OR REPLACE FUNCTION "gw_ledger".protocol_valid(
  i_protocol_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_name JSONB;
    v_methods_root BYTEA;
    v_name_root BYTEA;
  BEGIN
    IF NOT "gw_ledger".record_kind(i_protocol_root,'protocol') THEN
      RETURN false;
    END IF;
    v_name_root := "gw_ledger".record_field(i_protocol_root,'protocol/name');
    v_methods_root := "gw_ledger".record_field(i_protocol_root,'protocol/methods');
    o_name := "gw_ledger".cell_by_hash(v_name_root);
    RETURN o_name IS NOT NULL AND ((o_name ->> 'type_tag')::SMALLINT = 7) AND "gw_ledger".protocol_methods_valid(v_methods_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/protocol-method-put [152] 
CREATE OR REPLACE FUNCTION "gw_ledger".protocol_method_put(
  i_protocol_root BYTEA,
  i_name_root BYTEA,
  i_arity_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_complete BYTEA;
    v_name BYTEA;
    v_protocol BYTEA;
    v_record BYTEA;
  BEGIN
    IF NOT ("gw_ledger".protocol_valid(i_protocol_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_protocol','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-protocol'
      ;
    END IF;
    v_record := "gw_ledger".record_start('protocol-method');
    v_protocol := "gw_ledger".record_assoc(v_record,'protocol/root',i_protocol_root);
    v_name := "gw_ledger".record_assoc(v_protocol,'method/name',i_name_root);
    v_complete := "gw_ledger".record_assoc(v_name,'method/arity',i_arity_root);
    RETURN v_complete;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/protocol-method-valid [165] 
CREATE OR REPLACE FUNCTION "gw_ledger".protocol_method_valid(
  i_method_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    v_arity_root BYTEA;
    v_name_root BYTEA;
    v_protocol_root BYTEA;
  BEGIN
    IF NOT "gw_ledger".record_kind(i_method_root,'protocol-method') THEN
      RETURN false;
    END IF;
    v_protocol_root := "gw_ledger".record_field(i_method_root,'protocol/root');
    v_name_root := "gw_ledger".record_field(i_method_root,'method/name');
    v_arity_root := "gw_ledger".record_field(i_method_root,'method/arity');
    RETURN "gw_ledger".protocol_valid(v_protocol_root) AND ("gw_ledger".cell_type_tag(v_name_root) = 7) AND ("gw_ledger".cell_type_tag(v_arity_root) = 2) AND ("gw_ledger".integer_bigint(v_arity_root) >= 1);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/protocol-bindings-available-at [179] 
CREATE OR REPLACE FUNCTION "gw_ledger".protocol_bindings_available_at(
  i_account_root BYTEA,
  i_protocol_root BYTEA,
  i_methods_root BYTEA,
  i_position INTEGER,
  i_count INTEGER
) RETURNS BOOLEAN AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN true;
  ELSE
    DECLARE
    v_arity_root BYTEA;
      v_existing BYTEA;
      v_method_root BYTEA;
      v_name_root BYTEA;
  BEGIN
    v_name_root := "gw_ledger".cell_ref_child(i_methods_root,i_position,'key');
      v_arity_root := "gw_ledger".cell_ref_child(i_methods_root,i_position,'value');
      v_method_root := "gw_ledger".protocol_method_put(i_protocol_root,v_name_root,v_arity_root);
      v_existing := "gw_ledger".account_value_lookup(i_account_root,v_name_root);
      IF v_existing IS NULL OR (v_existing = v_method_root) THEN
        RETURN "gw_ledger".protocol_bindings_available_at(
          i_account_root,
          i_protocol_root,
          i_methods_root,
          i_position + 1,
          i_count
        );
      ELSE
        RETURN false;
      END IF;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/protocol-bind-methods-at [202] 
CREATE OR REPLACE FUNCTION "gw_ledger".protocol_bind_methods_at(
  i_account_root BYTEA,
  i_protocol_root BYTEA,
  i_methods_root BYTEA,
  i_position INTEGER,
  i_count INTEGER
) RETURNS BYTEA AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN i_account_root;
  ELSE
    DECLARE
    v_arity_root BYTEA;
      v_method_root BYTEA;
      v_name_root BYTEA;
      v_next_account BYTEA;
  BEGIN
    v_name_root := "gw_ledger".cell_ref_child(i_methods_root,i_position,'key');
      v_arity_root := "gw_ledger".cell_ref_child(i_methods_root,i_position,'value');
      v_method_root := "gw_ledger".protocol_method_put(i_protocol_root,v_name_root,v_arity_root);
      v_next_account := "gw_ledger".account_value_define(i_account_root,v_name_root,v_method_root);
      RETURN "gw_ledger".protocol_bind_methods_at(
        v_next_account,
        i_protocol_root,
        i_methods_root,
        i_position + 1,
        i_count
      );
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/define-transition [222] 
CREATE OR REPLACE FUNCTION "gw_ledger".define_transition(
  i_context_root BYTEA,
  i_name_root BYTEA,
  i_methods_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_context JSONB;
    v_account_root BYTEA;
    v_cost INTEGER;
    v_count INTEGER;
    v_existing BYTEA;
    v_next_account BYTEA;
    v_next_context BYTEA;
    v_next_state BYTEA;
    v_protocol_root BYTEA;
    v_with_protocol BYTEA;
  BEGIN
    o_context := "gw_ledger".context_get(i_context_root);
    IF o_context is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'missing-context');
    END IF;
    IF NOT "gw_ledger".protocol_methods_valid(i_methods_root) THEN
      RETURN "gw_ledger".result_error(i_context_root,'invalid-protocol-methods');
    END IF;
    v_count := "gw_ledger".cell_ref_count(i_methods_root,'key');
    v_cost := (4 + (2 * v_count));
    IF NOT "gw_ledger".context_can_charge(i_context_root,v_cost) THEN
      RETURN "gw_ledger".result_error(i_context_root,'cost-limit');
    END IF;
    v_account_root := "gw_ledger".state_account_root(
      (o_context ->> 'state_root')::BYTEA,
      (o_context ->> 'address')::BYTEA
    );
    IF v_account_root is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'missing-account');
    END IF;
    v_protocol_root := "gw_ledger".protocol_put(i_name_root,i_methods_root);
    v_existing := "gw_ledger".account_value_lookup(v_account_root,i_name_root);
    IF NOT (v_existing IS NULL OR (v_existing = v_protocol_root)) THEN
      RETURN "gw_ledger".result_error(i_context_root,'protocol-binding-conflict');
    END IF;
    IF NOT "gw_ledger".protocol_bindings_available_at(v_account_root,v_protocol_root,i_methods_root,0,v_count) THEN
      RETURN "gw_ledger".result_error(i_context_root,'protocol-method-binding-conflict');
    END IF;
    v_with_protocol := "gw_ledger".account_value_define(v_account_root,i_name_root,v_protocol_root);
    v_next_account := "gw_ledger".protocol_bind_methods_at(v_with_protocol,v_protocol_root,i_methods_root,0,v_count);
    v_next_state := "gw_ledger".state_assoc_account(
      (o_context ->> 'state_root')::BYTEA,
      (o_context ->> 'address')::BYTEA,
      v_next_account,
      (o_context ->> 'block_height')::BIGINT
    );
    v_next_context := "gw_ledger".context_charge(
      "gw_ledger".context_with_state(i_context_root,v_next_state),
      v_cost
    );
    RETURN "gw_ledger".result_ok(v_next_context,v_protocol_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/type-put [265] 
CREATE OR REPLACE FUNCTION "gw_ledger".type_put(
  i_name_root BYTEA,
  i_representation_tag INTEGER
) RETURNS BYTEA AS $$

  DECLARE
    v_complete BYTEA;
    v_named BYTEA;
    v_record BYTEA;
  BEGIN
    IF NOT ("gw_ledger".cell_type_tag(i_name_root) = 7) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/type_name_not_symbol','data',null))::TEXT,
        MESSAGE = 'ledger/type-name-not-symbol'
      ;
    END IF;
    IF NOT ((i_representation_tag >= 0) AND (i_representation_tag <= 20)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_representation_tag',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-representation-tag'
      ;
    END IF;
    v_record := "gw_ledger".record_start('type');
    v_named := "gw_ledger".record_assoc(v_record,'type/name',i_name_root);
    v_complete := "gw_ledger".record_assoc(
      v_named,
      'type/representation-tag',
      "gw_ledger".put_integer_number(i_representation_tag)
    );
    RETURN v_complete;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/type-valid [282] 
CREATE OR REPLACE FUNCTION "gw_ledger".type_valid(
  i_type_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    v_name_root BYTEA;
    v_tag_root BYTEA;
  BEGIN
    IF NOT "gw_ledger".record_kind(i_type_root,'type') THEN
      RETURN false;
    END IF;
    v_name_root := "gw_ledger".record_field(i_type_root,'type/name');
    v_tag_root := "gw_ledger".record_field(i_type_root,'type/representation-tag');
    RETURN ("gw_ledger".cell_type_tag(v_name_root) = 7) AND ("gw_ledger".cell_type_tag(v_tag_root) = 2) AND ("gw_ledger".integer_bigint(v_tag_root) >= 0) AND ("gw_ledger".integer_bigint(v_tag_root) <= 20);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/builtin-type-put [294] 
CREATE OR REPLACE FUNCTION "gw_ledger".builtin_type_put(
  i_type_tag INTEGER
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".type_put(
    "gw_ledger".put_symbol('hara.type/' || (i_type_tag)::TEXT),
    i_type_tag
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/typed-value-put [302] 
CREATE OR REPLACE FUNCTION "gw_ledger".typed_value_put(
  i_type_root BYTEA,
  i_value_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_complete BYTEA;
    v_record BYTEA;
    v_typed BYTEA;
  BEGIN
    IF NOT ("gw_ledger".type_valid(i_type_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_type_descriptor',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-type-descriptor'
      ;
    END IF;
    IF NOT ("gw_ledger".cell_by_hash(i_value_root) IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_typed_value','data',null))::TEXT,
        MESSAGE = 'ledger/missing-typed-value'
      ;
    END IF;
    v_record := "gw_ledger".record_start('typed-value');
    v_typed := "gw_ledger".record_assoc(v_record,'typed/type',i_type_root);
    v_complete := "gw_ledger".record_assoc(v_typed,'typed/value',i_value_root);
    RETURN v_complete;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/typed-value-valid [316] 
CREATE OR REPLACE FUNCTION "gw_ledger".typed_value_valid(
  i_typed_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    v_type_root BYTEA;
    v_value_root BYTEA;
  BEGIN
    IF NOT "gw_ledger".record_kind(i_typed_root,'typed-value') THEN
      RETURN false;
    END IF;
    v_type_root := "gw_ledger".record_field(i_typed_root,'typed/type');
    v_value_root := "gw_ledger".record_field(i_typed_root,'typed/value');
    RETURN "gw_ledger".type_valid(v_type_root) AND "gw_ledger".cell_by_hash(v_value_root) IS NOT NULL;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/value-type-root [327] 
CREATE OR REPLACE FUNCTION "gw_ledger".value_type_root(
  i_value_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_cell JSONB;
  BEGIN
    o_cell := "gw_ledger".cell_by_hash(i_value_root);
    IF o_cell is null  THEN
      RETURN null;
    ELSIF "gw_ledger".typed_value_valid(i_value_root) THEN
      RETURN "gw_ledger".record_field(i_value_root,'typed/type');
    ELSE
      RETURN "gw_ledger".builtin_type_put((o_cell ->> 'type_tag')::SMALLINT);
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/implementation-methods-valid-at [339] 
CREATE OR REPLACE FUNCTION "gw_ledger".implementation_methods_valid_at(
  i_protocol_methods_root BYTEA,
  i_methods_root BYTEA,
  i_position INTEGER,
  i_count INTEGER
) RETURNS BOOLEAN AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN true;
  ELSE
    DECLARE
    o_function JSONB;
      v_arity_root BYTEA;
      v_function_root BYTEA;
      v_name_root BYTEA;
      v_parameter_count INTEGER;
  BEGIN
    v_name_root := "gw_ledger".cell_ref_child(i_protocol_methods_root,i_position,'key');
      v_arity_root := "gw_ledger".cell_ref_child(i_protocol_methods_root,i_position,'value');
      v_function_root := "gw_ledger".map_get(i_methods_root,v_name_root);
      o_function := "gw_ledger".function_get(v_function_root);
      v_parameter_count := CASE WHEN o_function IS NULL THEN -1
      ELSE "gw_ledger".cell_ref_count((o_function ->> 'parameters_root')::BYTEA,'element')
      END;
      IF v_function_root IS NULL OR o_function IS NULL OR NOT "gw_ledger".function_valid(v_function_root) OR NOT (v_parameter_count = "gw_ledger".integer_bigint(v_arity_root)) THEN
        RETURN false;
      ELSE
        RETURN "gw_ledger".implementation_methods_valid_at(i_protocol_methods_root,i_methods_root,i_position + 1,i_count);
      END IF;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/implementation-methods-valid [368] 
CREATE OR REPLACE FUNCTION "gw_ledger".implementation_methods_valid(
  i_protocol_root BYTEA,
  i_methods_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_methods JSONB;
    v_count INTEGER;
    v_protocol_methods_root BYTEA;
  BEGIN
    IF NOT "gw_ledger".protocol_valid(i_protocol_root) THEN
      RETURN false;
    END IF;
    v_protocol_methods_root := "gw_ledger".record_field(i_protocol_root,'protocol/methods');
    o_methods := "gw_ledger".cell_by_hash(i_methods_root);
    IF o_methods IS NULL OR NOT ((o_methods ->> 'type_tag')::SMALLINT = 11) THEN
      RETURN false;
    END IF;
    v_count := "gw_ledger".cell_ref_count(v_protocol_methods_root,'key');
    RETURN (v_count = "gw_ledger".cell_ref_count(i_methods_root,'key')) AND "gw_ledger".implementation_methods_valid_at(v_protocol_methods_root,i_methods_root,0,v_count);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/implementation-put [385] 
CREATE OR REPLACE FUNCTION "gw_ledger".implementation_put(
  i_protocol_root BYTEA,
  i_type_root BYTEA,
  i_methods_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_complete BYTEA;
    v_protocol BYTEA;
    v_record BYTEA;
    v_type BYTEA;
  BEGIN
    IF NOT ("gw_ledger".protocol_valid(i_protocol_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_protocol','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-protocol'
      ;
    END IF;
    IF NOT ("gw_ledger".type_valid(i_type_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_type_descriptor',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-type-descriptor'
      ;
    END IF;
    IF NOT ("gw_ledger".implementation_methods_valid(i_protocol_root,i_methods_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_protocol_implementation',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-protocol-implementation'
      ;
    END IF;
    v_record := "gw_ledger".record_start('protocol-implementation');
    v_protocol := "gw_ledger".record_assoc(v_record,'implementation/protocol',i_protocol_root);
    v_type := "gw_ledger".record_assoc(v_protocol,'implementation/type',i_type_root);
    v_complete := "gw_ledger".record_assoc(v_type,'implementation/methods',i_methods_root);
    RETURN v_complete;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/implementation-valid [405] 
CREATE OR REPLACE FUNCTION "gw_ledger".implementation_valid(
  i_implementation_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    v_methods_root BYTEA;
    v_protocol_root BYTEA;
    v_type_root BYTEA;
  BEGIN
    IF NOT "gw_ledger".record_kind(i_implementation_root,'protocol-implementation') THEN
      RETURN false;
    END IF;
    v_protocol_root := "gw_ledger".record_field(i_implementation_root,'implementation/protocol');
    v_type_root := "gw_ledger".record_field(i_implementation_root,'implementation/type');
    v_methods_root := "gw_ledger".record_field(i_implementation_root,'implementation/methods');
    RETURN "gw_ledger".type_valid(v_type_root) AND "gw_ledger".implementation_methods_valid(v_protocol_root,v_methods_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/implementation-key-root [422] 
CREATE OR REPLACE FUNCTION "gw_ledger".implementation_key_root(
  i_protocol_root BYTEA,
  i_type_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_symbol(
    'ignatius.protocol.impl/' || encode(i_protocol_root,'hex') || '/' || encode(i_type_root,'hex')
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/extend-transition [432] 
CREATE OR REPLACE FUNCTION "gw_ledger".extend_transition(
  i_context_root BYTEA,
  i_protocol_name_root BYTEA,
  i_type_root BYTEA,
  i_methods_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_context JSONB;
    v_account_root BYTEA;
    v_cost INTEGER;
    v_count INTEGER;
    v_existing BYTEA;
    v_implementation_root BYTEA;
    v_key_root BYTEA;
    v_next_account BYTEA;
    v_next_context BYTEA;
    v_next_state BYTEA;
    v_protocol_root BYTEA;
  BEGIN
    o_context := "gw_ledger".context_get(i_context_root);
    IF o_context is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'missing-context');
    END IF;
    v_account_root := "gw_ledger".state_account_root(
      (o_context ->> 'state_root')::BYTEA,
      (o_context ->> 'address')::BYTEA
    );
    IF v_account_root is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'missing-account');
    END IF;
    v_protocol_root := "gw_ledger".account_value_lookup(v_account_root,i_protocol_name_root);
    IF v_protocol_root IS NULL OR NOT "gw_ledger".protocol_valid(v_protocol_root) THEN
      RETURN "gw_ledger".result_error(i_context_root,'missing-protocol');
    END IF;
    IF NOT "gw_ledger".implementation_methods_valid(v_protocol_root,i_methods_root) THEN
      RETURN "gw_ledger".result_error(i_context_root,'invalid-protocol-implementation');
    END IF;
    v_count := "gw_ledger".cell_ref_count(i_methods_root,'key');
    v_cost := (4 + (2 * v_count));
    IF NOT "gw_ledger".context_can_charge(i_context_root,v_cost) THEN
      RETURN "gw_ledger".result_error(i_context_root,'cost-limit');
    END IF;
    v_implementation_root := "gw_ledger".implementation_put(v_protocol_root,i_type_root,i_methods_root);
    v_key_root := "gw_ledger".implementation_key_root(v_protocol_root,i_type_root);
    v_existing := "gw_ledger".account_value_lookup(v_account_root,v_key_root);
    IF NOT (v_existing IS NULL OR (v_existing = v_implementation_root)) THEN
      RETURN "gw_ledger".result_error(i_context_root,'protocol-implementation-conflict');
    END IF;
    v_next_account := "gw_ledger".account_value_define(v_account_root,v_key_root,v_implementation_root);
    v_next_state := "gw_ledger".state_assoc_account(
      (o_context ->> 'state_root')::BYTEA,
      (o_context ->> 'address')::BYTEA,
      v_next_account,
      (o_context ->> 'block_height')::BIGINT
    );
    v_next_context := "gw_ledger".context_charge(
      "gw_ledger".context_with_state(i_context_root,v_next_state),
      v_cost
    );
    RETURN "gw_ledger".result_ok(v_next_context,v_implementation_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/resolve-method [483] 
CREATE OR REPLACE FUNCTION "gw_ledger".resolve_method(
  i_state_root BYTEA,
  i_address_root BYTEA,
  i_protocol_root BYTEA,
  i_method_name_root BYTEA,
  i_receiver_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_account_root BYTEA;
    v_implementation_root BYTEA;
    v_key_root BYTEA;
    v_methods_root BYTEA;
    v_type_root BYTEA;
  BEGIN
    v_account_root := "gw_ledger".state_account_root(i_state_root,i_address_root);
    v_type_root := "gw_ledger".value_type_root(i_receiver_root);
    v_key_root := CASE WHEN v_type_root IS NULL THEN null
    ELSE "gw_ledger".implementation_key_root(i_protocol_root,v_type_root)
    END;
    v_implementation_root := CASE WHEN v_account_root IS NULL OR v_key_root IS NULL THEN null
    ELSE "gw_ledger".account_value_lookup(v_account_root,v_key_root)
    END;
    v_methods_root := CASE WHEN "gw_ledger".implementation_valid(v_implementation_root) THEN "gw_ledger".record_field(v_implementation_root,'implementation/methods')
    ELSE null
    END;
    RETURN CASE WHEN v_methods_root IS NULL THEN null
    ELSE "gw_ledger".map_get(v_methods_root,i_method_name_root)
    END;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol/method-arity [506] 
CREATE OR REPLACE FUNCTION "gw_ledger".method_arity(
  i_protocol_root BYTEA,
  i_method_name_root BYTEA
) RETURNS BIGINT AS $$

  DECLARE
    v_arity_root BYTEA;
    v_methods_root BYTEA;
  BEGIN
    v_methods_root := CASE WHEN "gw_ledger".protocol_valid(i_protocol_root) THEN "gw_ledger".record_field(i_protocol_root,'protocol/methods')
    ELSE null
    END;
    v_arity_root := CASE WHEN v_methods_root IS NULL THEN null
    ELSE "gw_ledger".map_get(v_methods_root,i_method_name_root)
    END;
    RETURN CASE WHEN v_arity_root IS NULL THEN -1
    ELSE "gw_ledger".integer_bigint(v_arity_root)
    END;
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

-- gwdb.ledger.actor/root-hex [27] 
CREATE OR REPLACE FUNCTION "gw_ledger".root_hex(
  i_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN CASE WHEN i_root IS NULL THEN '-'
  ELSE encode(i_root,'hex')
  END;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.actor/special-name [35] 
CREATE OR REPLACE FUNCTION "gw_ledger".special_name(
  i_op_root BYTEA
) RETURNS TEXT AS $$

  DECLARE
    o_op JSONB;
    o_symbol JSONB;
  BEGIN
    o_op := "gw_ledger".op_get(i_op_root);
    o_symbol := "gw_ledger".cell_by_hash((o_op ->> 'symbol_root')::BYTEA);
    RETURN CASE WHEN o_op IS NULL OR o_symbol IS NULL THEN ''
    ELSE encode((o_symbol ->> 'payload')::BYTEA,'escape')
    END;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.actor/actor-address-payload [48] 
CREATE OR REPLACE FUNCTION "gw_ledger".actor_address_payload(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_context JSONB;
  BEGIN
    o_context := "gw_ledger".context_get(i_context_root);
    RETURN decode(
      'R:actor-address:1:4:' || "gw_ledger".root_hex((o_context ->> 'transaction_root')::BYTEA) || ':' || "gw_ledger".root_hex((o_context ->> 'address')::BYTEA) || ':' || "gw_ledger".root_hex(i_op_root) || ':' || ((o_context ->> 'cost_used')::BIGINT)::TEXT,
      'escape'
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.actor/actor-address-root [63] 
CREATE OR REPLACE FUNCTION "gw_ledger".actor_address_root(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_blob("gw_ledger".canonical_hash(
    14,
    "gw_ledger".actor_address_payload(i_context_root,i_op_root)
  ));
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.actor/callable-metadata [73] 
CREATE OR REPLACE FUNCTION "gw_ledger".callable_metadata() RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".map_assoc(
    "gw_ledger".put_map(jsonb_build_array()),
    "gw_ledger".put_keyword('callable'),
    "gw_ledger".put_boolean(true)
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.actor/definition-callable [84] 
CREATE OR REPLACE FUNCTION "gw_ledger".definition_callable(
  i_account_root BYTEA,
  i_symbol_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_metadata JSONB;
    v_callable_root BYTEA;
    v_metadata_root BYTEA;
  BEGIN
    v_metadata_root := "gw_ledger".account_value_definition_metadata(i_account_root,i_symbol_root);
    o_metadata := "gw_ledger".cell_by_hash(v_metadata_root);
    v_callable_root := CASE WHEN o_metadata IS NULL OR NOT ((o_metadata ->> 'type_tag')::SMALLINT = 11) THEN null
    ELSE "gw_ledger".map_get(v_metadata_root,"gw_ledger".put_keyword('callable'))
    END;
    RETURN v_callable_root = "gw_ledger".put_boolean(true);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.actor/callable-function-root [101] 
CREATE OR REPLACE FUNCTION "gw_ledger".callable_function_root(
  i_state_root BYTEA,
  i_address_root BYTEA,
  i_symbol_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_account_root BYTEA;
    v_function_root BYTEA;
  BEGIN
    v_account_root := "gw_ledger".state_account_root(i_state_root,i_address_root);
    v_function_root := CASE WHEN v_account_root IS NULL THEN null
    ELSE "gw_ledger".account_value_lookup(v_account_root,i_symbol_root)
    END;
    RETURN CASE WHEN v_account_root IS NOT NULL AND "gw_ledger".definition_callable(v_account_root,i_symbol_root) AND "gw_ledger".function_valid(v_function_root) THEN v_function_root
    ELSE null
    END;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.actor/context-enter [121] 
CREATE OR REPLACE FUNCTION "gw_ledger".context_enter(
  i_context_root BYTEA,
  i_state_root BYTEA,
  i_address_root BYTEA,
  i_caller_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_context JSONB;
  BEGIN
    o_context := "gw_ledger".context_get(i_context_root);
    RETURN "gw_ledger".context_create(
      i_state_root,
      (o_context ->> 'origin')::BYTEA,
      i_address_root,
      i_caller_root,
      (o_context ->> 'transaction_root')::BYTEA,
      (o_context ->> 'block_height')::BIGINT,
      (o_context ->> 'timestamp')::BIGINT,
      "gw_ledger".put_vector(jsonb_build_array()),
      (o_context ->> 'cost_used')::BIGINT,
      (o_context ->> 'cost_limit')::BIGINT,
      (o_context ->> 'depth')::INTEGER + 1
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.actor/context-restore [142] 
CREATE OR REPLACE FUNCTION "gw_ledger".context_restore(
  i_outer_context_root BYTEA,
  i_inner_context_root BYTEA,
  i_state_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_inner JSONB;
    o_outer JSONB;
  BEGIN
    o_outer := "gw_ledger".context_get(i_outer_context_root);
    o_inner := "gw_ledger".context_get(i_inner_context_root);
    RETURN "gw_ledger".context_create(
      i_state_root,
      (o_outer ->> 'origin')::BYTEA,
      (o_outer ->> 'address')::BYTEA,
      (o_outer ->> 'caller')::BYTEA,
      (o_outer ->> 'transaction_root')::BYTEA,
      (o_outer ->> 'block_height')::BIGINT,
      (o_outer ->> 'timestamp')::BIGINT,
      (o_outer ->> 'locals_root')::BYTEA,
      (o_inner ->> 'cost_used')::BIGINT,
      (o_outer ->> 'cost_limit')::BIGINT,
      (o_outer ->> 'depth')::INTEGER
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.actor/deploy-state [164] 
CREATE OR REPLACE FUNCTION "gw_ledger".deploy_state(
  i_context_root BYTEA,
  i_actor_address_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_context JSONB;
    v_account_root BYTEA;
    v_controller_root BYTEA;
    v_existing BYTEA;
    v_state_root BYTEA;
  BEGIN
    o_context := "gw_ledger".context_get(i_context_root);
    v_state_root := (o_context ->> 'state_root')::BYTEA;
    v_controller_root := (o_context ->> 'address')::BYTEA;
    v_existing := "gw_ledger".state_account_root(v_state_root,i_actor_address_root);
    IF NOT (v_existing IS NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/actor_address_exists','data',null))::TEXT,
        MESSAGE = 'ledger/actor-address-exists'
      ;
    END IF;
    v_account_root := "gw_ledger".account_value_create_actor(v_controller_root,v_controller_root);
    RETURN "gw_ledger".state_assoc_account(
      v_state_root,
      i_actor_address_root,
      v_account_root,
      (o_context ->> 'block_height')::BIGINT
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.actor/deploy-op [183] 
CREATE OR REPLACE FUNCTION "gw_ledger".deploy_op(
  i_initializer_op_root BYTEA,
  i_callable_symbols_root BYTEA
) RETURNS BYTEA AS $$

  BEGIN
    IF NOT ("gw_ledger".cell_type_tag(i_callable_symbols_root) = 10) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/actor_callables_not_vector',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/actor-callables-not-vector'
      ;
    END IF;
    RETURN "gw_ledger".put_op(
      'special',
      i_callable_symbols_root,
      "gw_ledger".put_symbol('actor/deploy'),
      null,
      null,
      null,
      null,
      null,
      jsonb_build_array(encode(i_initializer_op_root,'hex'))
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.actor/actor-call-op [198] 
CREATE OR REPLACE FUNCTION "gw_ledger".actor_call_op(
  i_target_op_root BYTEA,
  i_method_symbol_root BYTEA,
  i_argument_op_roots JSONB
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_op(
    'special',
    i_method_symbol_root,
    "gw_ledger".put_symbol('actor/call'),
    null,
    null,
    null,
    null,
    null,
    jsonb_build_array(encode(i_target_op_root,'hex')) || i_argument_op_roots
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.actor/actor-query-op [211] 
CREATE OR REPLACE FUNCTION "gw_ledger".actor_query_op(
  i_target_op_root BYTEA,
  i_method_symbol_root BYTEA,
  i_argument_op_roots JSONB
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_op(
    'special',
    i_method_symbol_root,
    "gw_ledger".put_symbol('actor/query'),
    null,
    null,
    null,
    null,
    null,
    jsonb_build_array(encode(i_target_op_root,'hex')) || i_argument_op_roots
  );
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

  SELECT ((i_primitive_id = 'integer/add') AND (i_arity = 2)) OR ((i_primitive_id = 'integer/subtract') AND (i_arity = 2)) OR ((i_primitive_id = 'integer/multiply') AND (i_arity = 2)) OR ((i_primitive_id = 'integer/less-than') AND (i_arity = 2)) OR ((i_primitive_id = 'integer/less-than-or-equal') AND (i_arity = 2)) OR ((i_primitive_id = 'integer/greater-than') AND (i_arity = 2)) OR ((i_primitive_id = 'integer/greater-than-or-equal') AND (i_arity = 2)) OR ((i_primitive_id = 'integer/equal') AND (i_arity = 2)) OR ((i_primitive_id = 'value/equal') AND (i_arity = 2)) OR ((i_primitive_id = 'boolean/not') AND (i_arity = 1)) OR ((i_primitive_id = 'vector/new') AND (i_arity = -1)) OR ((i_primitive_id = 'vector/count') AND (i_arity = 1)) OR ((i_primitive_id = 'vector/get') AND (i_arity = 2)) OR ((i_primitive_id = 'map/new') AND (i_arity = -1)) OR ((i_primitive_id = 'map/get') AND (i_arity = 2)) OR ((i_primitive_id = 'map/assoc') AND (i_arity = 3)) OR ((i_primitive_id = 'string/concat') AND (i_arity = -1)) OR ((i_primitive_id = 'account/exists') AND (i_arity = 1)) OR ((i_primitive_id = 'account/root') AND (i_arity = 1)) OR ((i_primitive_id = 'account/sequence') AND (i_arity = 1)) OR ((i_primitive_id = 'account/key') AND (i_arity = 1)) OR ((i_primitive_id = 'account/controller') AND (i_arity = 1)) OR ((i_primitive_id = 'account/environment') AND (i_arity = 1)) OR ((i_primitive_id = 'account/metadata') AND (i_arity = 1)) OR ((i_primitive_id = 'account/set-key') AND (i_arity = 1)) OR ((i_primitive_id = 'account/set-controller') AND (i_arity = 1)) OR ((i_primitive_id = 'account/set-definition-metadata') AND (i_arity = 2)) OR ((i_primitive_id = 'protocol/define') AND (i_arity = 2)) OR ((i_primitive_id = 'protocol/extend') AND (i_arity = 3)) OR ((i_primitive_id = 'protocol/invoke') AND (i_arity = -1));

$$ LANGUAGE 'sql' IMMUTABLE PARALLEL SAFE;

-- gwdb.ledger.primitive/primitive-payload [62] 
CREATE OR REPLACE FUNCTION "gw_ledger".primitive_payload(
  i_primitive_id TEXT,
  i_arity INTEGER
) RETURNS BYTEA AS $$
BEGIN
  RETURN decode('P:1:' || i_primitive_id || ':' || i_arity,'escape');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.primitive/primitive-put [68] 
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

-- gwdb.ledger.primitive/primitive-get [83] 
CREATE OR REPLACE FUNCTION "gw_ledger".primitive_get(
  i_primitive_id TEXT
) RETURNS JSONB AS $$
BEGIN
  RETURN WITH j_ret AS (  
    SELECT "primitive_root","primitive_id","arity" FROM "gw_ledger"."Primitive"
    WHERE "primitive_id" = i_primitive_id
    LIMIT 1)
  SELECT to_jsonb(j_ret) FROM j_ret;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.primitive/primitive-get-root [90] 
CREATE OR REPLACE FUNCTION "gw_ledger".primitive_get_root(
  i_primitive_root BYTEA
) RETURNS JSONB AS $$
BEGIN
  RETURN WITH j_ret AS (  
    SELECT "primitive_root","primitive_id","arity" FROM "gw_ledger"."Primitive"
    WHERE "primitive_root" = i_primitive_root
    LIMIT 1)
  SELECT to_jsonb(j_ret) FROM j_ret;
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

-- gwdb.ledger.runtime-support/root-at [19] 
CREATE OR REPLACE FUNCTION "gw_ledger".root_at(
  i_roots JSONB,
  i_position INTEGER
) RETURNS BYTEA AS $$
BEGIN
  RETURN decode((i_roots ->> i_position)::TEXT,'hex');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-support/roots-tail-at [25] 
CREATE OR REPLACE FUNCTION "gw_ledger".roots_tail_at(
  i_roots JSONB,
  i_position INTEGER,
  i_count INTEGER,
  i_out JSONB
) RETURNS JSONB AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN i_out;
  ELSE
    RETURN "gw_ledger".roots_tail_at(
      i_roots,
      i_position + 1,
      i_count,
      i_out || jsonb_build_array((i_roots ->> i_position)::TEXT)
    );
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-support/truthy [38] 
CREATE OR REPLACE FUNCTION "gw_ledger".truthy(
  i_value_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_cell JSONB;
  BEGIN
    o_cell := "gw_ledger".cell_by_hash(i_value_root);
    RETURN o_cell IS NOT NULL AND NOT ((o_cell ->> 'type_tag')::SMALLINT = 0) AND NOT (((o_cell ->> 'type_tag')::SMALLINT = 1) AND ((o_cell ->> 'payload')::BYTEA = decode('00','hex')));
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-support/integer-root [51] 
CREATE OR REPLACE FUNCTION "gw_ledger".integer_root(
  i_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_cell JSONB;
  BEGIN
    o_cell := "gw_ledger".cell_by_hash(i_root);
    RETURN o_cell IS NOT NULL AND ((o_cell ->> 'type_tag')::SMALLINT = 2);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-support/vector-roots-at [59] 
CREATE OR REPLACE FUNCTION "gw_ledger".vector_roots_at(
  i_vector_root BYTEA,
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
    v_root := "gw_ledger".cell_ref_child(i_vector_root,i_position,'element');
      v_next := (i_out || jsonb_build_array(encode(v_root,'hex')));
      RETURN "gw_ledger".vector_roots_at(i_vector_root,i_position + 1,i_count,v_next);
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-support/vector-roots [75] 
CREATE OR REPLACE FUNCTION "gw_ledger".vector_roots(
  i_vector_root BYTEA
) RETURNS JSONB AS $$

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
    RETURN "gw_ledger".vector_roots_at(i_vector_root,0,v_count,jsonb_build_array());
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-support/evaluated-roots [87] 
CREATE OR REPLACE FUNCTION "gw_ledger".evaluated_roots(
  i_context_root BYTEA,
  i_roots JSONB
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
      'roots',
      i_roots,
      'cost_used',
      (o_context ->> 'cost_used')::BIGINT
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-support/map-from-roots-at [97] 
CREATE OR REPLACE FUNCTION "gw_ledger".map_from_roots_at(
  i_roots JSONB,
  i_position INTEGER,
  i_count INTEGER,
  i_map_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN i_map_root;
  ELSE
    DECLARE
    v_next BYTEA;
  BEGIN
    v_next := "gw_ledger".map_assoc(
        i_map_root,
        "gw_ledger".root_at(i_roots,i_position),
        "gw_ledger".root_at(i_roots,i_position + 1)
      );
      RETURN "gw_ledger".map_from_roots_at(i_roots,i_position + 2,i_count,v_next);
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-support/string-concat-at [111] 
CREATE OR REPLACE FUNCTION "gw_ledger".string_concat_at(
  i_roots JSONB,
  i_position INTEGER,
  i_count INTEGER,
  i_out TEXT
) RETURNS TEXT AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN i_out;
  ELSE
    DECLARE
    o_cell JSONB;
      v_next TEXT;
      v_root BYTEA;
  BEGIN
    v_root := "gw_ledger".root_at(i_roots,i_position);
      o_cell := "gw_ledger".cell_by_hash(v_root);
      IF o_cell IS NULL OR NOT ((o_cell ->> 'type_tag')::SMALLINT = 5) THEN
        RETURN null;
      END IF;
      v_next := (i_out || convert_from((o_cell ->> 'payload')::BYTEA,'UTF8'));
      RETURN "gw_ledger".string_concat_at(i_roots,i_position + 1,i_count,v_next);
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-support/apply-integer-binary [128] 
CREATE OR REPLACE FUNCTION "gw_ledger".apply_integer_binary(
  i_context_root BYTEA,
  i_primitive_id TEXT,
  i_roots JSONB
) RETURNS JSONB AS $$

  DECLARE
    v_left BIGINT;
    v_left_root BYTEA;
    v_next_context BYTEA;
    v_result_root BYTEA;
    v_right BIGINT;
    v_right_root BYTEA;
  BEGIN
    v_left_root := "gw_ledger".root_at(i_roots,0);
    v_right_root := "gw_ledger".root_at(i_roots,1);
    IF NOT ("gw_ledger".integer_root(v_left_root) AND "gw_ledger".integer_root(v_right_root)) THEN
      RETURN "gw_ledger".result_error(i_context_root,'integer-required');
    END IF;
    v_left := "gw_ledger".integer_bigint(v_left_root);
    v_right := "gw_ledger".integer_bigint(v_right_root);
    v_result_root := CASE WHEN i_primitive_id = 'integer/add' THEN "gw_ledger".put_integer_number(v_left + v_right)
    WHEN i_primitive_id = 'integer/subtract' THEN "gw_ledger".put_integer_number(v_left - v_right)
    WHEN i_primitive_id = 'integer/multiply' THEN "gw_ledger".put_integer_number(v_left * v_right)
    WHEN i_primitive_id = 'integer/less-than' THEN "gw_ledger".put_boolean(v_left < v_right)
    WHEN i_primitive_id = 'integer/less-than-or-equal' THEN "gw_ledger".put_boolean(v_left <= v_right)
    WHEN i_primitive_id = 'integer/greater-than' THEN "gw_ledger".put_boolean(v_left > v_right)
    WHEN i_primitive_id = 'integer/greater-than-or-equal' THEN "gw_ledger".put_boolean(v_left >= v_right)
    ELSE "gw_ledger".put_boolean(v_left = v_right)
    END;
    v_next_context := "gw_ledger".context_charge(i_context_root,1);
    RETURN "gw_ledger".result_ok(v_next_context,v_result_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-support/apply-vector-count [159] 
CREATE OR REPLACE FUNCTION "gw_ledger".apply_vector_count(
  i_context_root BYTEA,
  i_roots JSONB
) RETURNS JSONB AS $$

  DECLARE
    o_input JSONB;
    v_input_root BYTEA;
    v_result_root BYTEA;
  BEGIN
    v_input_root := "gw_ledger".root_at(i_roots,0);
    o_input := "gw_ledger".cell_by_hash(v_input_root);
    IF o_input IS NULL OR NOT ((o_input ->> 'type_tag')::SMALLINT = 10) THEN
      RETURN "gw_ledger".result_error(i_context_root,'vector-required');
    END IF;
    v_result_root := "gw_ledger".put_integer_number("gw_ledger".cell_ref_count(v_input_root,'element'));
    RETURN "gw_ledger".result_ok("gw_ledger".context_charge(i_context_root,1),v_result_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-support/apply-vector-get [175] 
CREATE OR REPLACE FUNCTION "gw_ledger".apply_vector_get(
  i_context_root BYTEA,
  i_roots JSONB
) RETURNS JSONB AS $$

  DECLARE
    o_input JSONB;
    v_found_root BYTEA;
    v_index INTEGER;
    v_index_root BYTEA;
    v_input_root BYTEA;
    v_result_root BYTEA;
  BEGIN
    v_input_root := "gw_ledger".root_at(i_roots,0);
    v_index_root := "gw_ledger".root_at(i_roots,1);
    o_input := "gw_ledger".cell_by_hash(v_input_root);
    IF o_input IS NULL OR NOT ((o_input ->> 'type_tag')::SMALLINT = 10) OR NOT "gw_ledger".integer_root(v_index_root) THEN
      RETURN "gw_ledger".result_error(i_context_root,'vector-and-index-required');
    END IF;
    v_index := ("gw_ledger".integer_bigint(v_index_root))::INTEGER;
    v_found_root := "gw_ledger".vector_get(v_input_root,v_index);
    v_result_root := CASE WHEN v_found_root IS NULL THEN "gw_ledger".put_nil()
    ELSE v_found_root
    END;
    RETURN "gw_ledger".result_ok("gw_ledger".context_charge(i_context_root,1),v_result_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-support/apply-map-new [197] 
CREATE OR REPLACE FUNCTION "gw_ledger".apply_map_new(
  i_context_root BYTEA,
  i_roots JSONB
) RETURNS JSONB AS $$

  DECLARE
    v_count INTEGER;
    v_result_root BYTEA;
  BEGIN
    v_count := jsonb_array_length(i_roots);
    IF NOT ((v_count % 2) = 0) THEN
      RETURN "gw_ledger".result_error(i_context_root,'map-even-arity');
    END IF;
    v_result_root := "gw_ledger".map_from_roots_at(i_roots,0,v_count,"gw_ledger".put_map(jsonb_build_array()));
    RETURN "gw_ledger".result_ok("gw_ledger".context_charge(i_context_root,1),v_result_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-support/apply-map-get [211] 
CREATE OR REPLACE FUNCTION "gw_ledger".apply_map_get(
  i_context_root BYTEA,
  i_roots JSONB
) RETURNS JSONB AS $$

  DECLARE
    o_input JSONB;
    v_found_root BYTEA;
    v_input_root BYTEA;
    v_result_root BYTEA;
  BEGIN
    v_input_root := "gw_ledger".root_at(i_roots,0);
    o_input := "gw_ledger".cell_by_hash(v_input_root);
    IF o_input IS NULL OR NOT ((o_input ->> 'type_tag')::SMALLINT = 11) THEN
      RETURN "gw_ledger".result_error(i_context_root,'map-required');
    END IF;
    v_found_root := "gw_ledger".map_get(v_input_root,"gw_ledger".root_at(i_roots,1));
    v_result_root := CASE WHEN v_found_root IS NULL THEN "gw_ledger".put_nil()
    ELSE v_found_root
    END;
    RETURN "gw_ledger".result_ok("gw_ledger".context_charge(i_context_root,1),v_result_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-support/apply-map-assoc [230] 
CREATE OR REPLACE FUNCTION "gw_ledger".apply_map_assoc(
  i_context_root BYTEA,
  i_roots JSONB
) RETURNS JSONB AS $$

  DECLARE
    o_input JSONB;
    v_input_root BYTEA;
    v_result_root BYTEA;
  BEGIN
    v_input_root := "gw_ledger".root_at(i_roots,0);
    o_input := "gw_ledger".cell_by_hash(v_input_root);
    IF o_input IS NULL OR NOT ((o_input ->> 'type_tag')::SMALLINT = 11) THEN
      RETURN "gw_ledger".result_error(i_context_root,'map-required');
    END IF;
    v_result_root := "gw_ledger".map_assoc(
      v_input_root,
      "gw_ledger".root_at(i_roots,1),
      "gw_ledger".root_at(i_roots,2)
    );
    RETURN "gw_ledger".result_ok("gw_ledger".context_charge(i_context_root,1),v_result_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-support/apply-string-concat [247] 
CREATE OR REPLACE FUNCTION "gw_ledger".apply_string_concat(
  i_context_root BYTEA,
  i_roots JSONB
) RETURNS JSONB AS $$

  DECLARE
    v_result_root BYTEA;
    v_result_text TEXT;
  BEGIN
    v_result_text := "gw_ledger".string_concat_at(i_roots,0,jsonb_array_length(i_roots),'');
    IF v_result_text is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'string-required');
    END IF;
    v_result_root := "gw_ledger".put_string(v_result_text);
    RETURN "gw_ledger".result_ok("gw_ledger".context_charge(i_context_root,1),v_result_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-support/apply-primitive [261] 
CREATE OR REPLACE FUNCTION "gw_ledger".apply_primitive(
  i_context_root BYTEA,
  i_primitive_id TEXT,
  i_roots JSONB
) RETURNS JSONB AS $$

  BEGIN
    IF NOT "gw_ledger".context_can_charge(i_context_root,1) THEN
      RETURN "gw_ledger".result_error(i_context_root,'cost-limit');
    END IF;
    IF (i_primitive_id = 'integer/add') OR (i_primitive_id = 'integer/subtract') OR (i_primitive_id = 'integer/multiply') OR (i_primitive_id = 'integer/less-than') OR (i_primitive_id = 'integer/less-than-or-equal') OR (i_primitive_id = 'integer/greater-than') OR (i_primitive_id = 'integer/greater-than-or-equal') OR (i_primitive_id = 'integer/equal') THEN
      RETURN "gw_ledger".apply_integer_binary(i_context_root,i_primitive_id,i_roots);
    ELSIF i_primitive_id = 'value/equal' THEN
      RETURN "gw_ledger".result_ok("gw_ledger".context_charge(i_context_root,1),"gw_ledger".put_boolean(
        "gw_ledger".root_at(i_roots,0) = "gw_ledger".root_at(i_roots,1)
      ));
    ELSIF i_primitive_id = 'boolean/not' THEN
      RETURN "gw_ledger".result_ok(
        "gw_ledger".context_charge(i_context_root,1),
        "gw_ledger".put_boolean(NOT "gw_ledger".truthy("gw_ledger".root_at(i_roots,0)))
      );
    ELSIF i_primitive_id = 'vector/new' THEN
      RETURN "gw_ledger".result_ok(
        "gw_ledger".context_charge(i_context_root,1),
        "gw_ledger".put_vector(i_roots)
      );
    ELSIF i_primitive_id = 'vector/count' THEN
      RETURN "gw_ledger".apply_vector_count(i_context_root,i_roots);
    ELSIF i_primitive_id = 'vector/get' THEN
      RETURN "gw_ledger".apply_vector_get(i_context_root,i_roots);
    ELSIF i_primitive_id = 'map/new' THEN
      RETURN "gw_ledger".apply_map_new(i_context_root,i_roots);
    ELSIF i_primitive_id = 'map/get' THEN
      RETURN "gw_ledger".apply_map_get(i_context_root,i_roots);
    ELSIF i_primitive_id = 'map/assoc' THEN
      RETURN "gw_ledger".apply_map_assoc(i_context_root,i_roots);
    ELSIF i_primitive_id = 'string/concat' THEN
      RETURN "gw_ledger".apply_string_concat(i_context_root,i_roots);
    ELSE
      RETURN "gw_ledger".result_error(i_context_root,'unknown-primitive');
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account-runtime/account-primitive-id [27] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_primitive_id(
  i_primitive_id TEXT
) RETURNS BOOLEAN AS $$
BEGIN
  RETURN (i_primitive_id = 'account/exists') OR (i_primitive_id = 'account/root') OR (i_primitive_id = 'account/sequence') OR (i_primitive_id = 'account/key') OR (i_primitive_id = 'account/controller') OR (i_primitive_id = 'account/environment') OR (i_primitive_id = 'account/metadata') OR (i_primitive_id = 'account/set-key') OR (i_primitive_id = 'account/set-controller') OR (i_primitive_id = 'account/set-definition-metadata');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account-runtime/account-root-at [43] 
CREATE OR REPLACE FUNCTION "gw_ledger".account_root_at(
  i_context_root BYTEA,
  i_address_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_context JSONB;
  BEGIN
    o_context := "gw_ledger".context_get(i_context_root);
    RETURN "gw_ledger".state_account_root((o_context ->> 'state_root')::BYTEA,i_address_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account-runtime/read-account-field [52] 
CREATE OR REPLACE FUNCTION "gw_ledger".read_account_field(
  i_context_root BYTEA,
  i_primitive_id TEXT,
  i_roots JSONB
) RETURNS JSONB AS $$

  DECLARE
    v_account_root BYTEA;
    v_address_root BYTEA;
    v_result_root BYTEA;
  BEGIN
    v_address_root := "gw_ledger".root_at(i_roots,0);
    v_account_root := "gw_ledger".account_root_at(i_context_root,v_address_root);
    v_result_root := CASE WHEN v_account_root IS NULL THEN "gw_ledger".put_nil()
    WHEN i_primitive_id = 'account/root' THEN v_account_root
    WHEN i_primitive_id = 'account/sequence' THEN "gw_ledger".account_value_sequence_root(v_account_root)
    WHEN i_primitive_id = 'account/key' THEN "gw_ledger".account_value_key_root(v_account_root)
    WHEN i_primitive_id = 'account/controller' THEN "gw_ledger".account_value_authority_root(v_account_root)
    WHEN i_primitive_id = 'account/environment' THEN "gw_ledger".account_value_environment_root(v_account_root)
    ELSE "gw_ledger".account_value_metadata_root(v_account_root)
    END;
    RETURN "gw_ledger".result_ok("gw_ledger".context_charge(i_context_root,1),v_result_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account-runtime/apply-account-exists [78] 
CREATE OR REPLACE FUNCTION "gw_ledger".apply_account_exists(
  i_context_root BYTEA,
  i_roots JSONB
) RETURNS JSONB AS $$

  DECLARE
    v_account_root BYTEA;
  BEGIN
    v_account_root := "gw_ledger".account_root_at(i_context_root,"gw_ledger".root_at(i_roots,0));
    RETURN "gw_ledger".result_ok("gw_ledger".context_charge(i_context_root,1),"gw_ledger".put_boolean(CASE WHEN v_account_root IS NULL THEN false
    ELSE true
    END));
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account-runtime/replace-current-account [92] 
CREATE OR REPLACE FUNCTION "gw_ledger".replace_current_account(
  i_context_root BYTEA,
  i_account_root BYTEA,
  i_cost BIGINT
) RETURNS BYTEA AS $$

  DECLARE
    o_context JSONB;
    v_state_root BYTEA;
  BEGIN
    o_context := "gw_ledger".context_get(i_context_root);
    v_state_root := "gw_ledger".state_assoc_account(
      (o_context ->> 'state_root')::BYTEA,
      (o_context ->> 'address')::BYTEA,
      i_account_root,
      (o_context ->> 'block_height')::BIGINT
    );
    RETURN "gw_ledger".context_charge(
      "gw_ledger".context_with_state(i_context_root,v_state_root),
      i_cost
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account-runtime/apply-account-set-key [109] 
CREATE OR REPLACE FUNCTION "gw_ledger".apply_account_set_key(
  i_context_root BYTEA,
  i_roots JSONB
) RETURNS JSONB AS $$

  DECLARE
    o_context JSONB;
    o_key JSONB;
    v_account_root BYTEA;
    v_key_root BYTEA;
    v_next_account BYTEA;
    v_next_context BYTEA;
  BEGIN
    o_context := "gw_ledger".context_get(i_context_root);
    v_account_root := "gw_ledger".state_account_root(
      (o_context ->> 'state_root')::BYTEA,
      (o_context ->> 'address')::BYTEA
    );
    IF v_account_root is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'missing-account');
    END IF;
    v_key_root := "gw_ledger".root_at(i_roots,0);
    o_key := "gw_ledger".cell_by_hash(v_key_root);
    IF o_key IS NULL OR NOT (((o_key ->> 'type_tag')::SMALLINT = 0) OR "gw_ledger".public_key_root_valid(v_key_root)) THEN
      RETURN "gw_ledger".result_error(i_context_root,'invalid-account-key');
    END IF;
    v_next_account := "gw_ledger".account_value_set_key(v_account_root,v_key_root);
    v_next_context := "gw_ledger".replace_current_account(i_context_root,v_next_account,3);
    RETURN "gw_ledger".result_ok(v_next_context,v_key_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account-runtime/apply-account-set-controller [134] 
CREATE OR REPLACE FUNCTION "gw_ledger".apply_account_set_controller(
  i_context_root BYTEA,
  i_roots JSONB
) RETURNS JSONB AS $$

  DECLARE
    o_context JSONB;
    v_account_root BYTEA;
    v_controller_root BYTEA;
    v_next_account BYTEA;
    v_next_context BYTEA;
  BEGIN
    o_context := "gw_ledger".context_get(i_context_root);
    v_account_root := "gw_ledger".state_account_root(
      (o_context ->> 'state_root')::BYTEA,
      (o_context ->> 'address')::BYTEA
    );
    IF v_account_root is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'missing-account');
    END IF;
    v_controller_root := "gw_ledger".root_at(i_roots,0);
    IF "gw_ledger".cell_by_hash(v_controller_root) is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'missing-controller-value');
    END IF;
    v_next_account := "gw_ledger".account_value_set_controller(v_account_root,v_controller_root);
    v_next_context := "gw_ledger".replace_current_account(i_context_root,v_next_account,3);
    RETURN "gw_ledger".result_ok(v_next_context,v_controller_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account-runtime/apply-account-set-definition-metadata [156] 
CREATE OR REPLACE FUNCTION "gw_ledger".apply_account_set_definition_metadata(
  i_context_root BYTEA,
  i_roots JSONB
) RETURNS JSONB AS $$

  DECLARE
    o_context JSONB;
    v_account_root BYTEA;
    v_metadata_root BYTEA;
    v_next_account BYTEA;
    v_next_context BYTEA;
    v_symbol_root BYTEA;
  BEGIN
    o_context := "gw_ledger".context_get(i_context_root);
    v_account_root := "gw_ledger".state_account_root(
      (o_context ->> 'state_root')::BYTEA,
      (o_context ->> 'address')::BYTEA
    );
    IF v_account_root is null  THEN
      RETURN "gw_ledger".result_error(i_context_root,'missing-account');
    END IF;
    v_symbol_root := "gw_ledger".root_at(i_roots,0);
    v_metadata_root := "gw_ledger".root_at(i_roots,1);
    IF NOT ("gw_ledger".cell_type_tag(v_symbol_root) = 7) THEN
      RETURN "gw_ledger".result_error(i_context_root,'definition-symbol-required');
    END IF;
    IF NOT ("gw_ledger".cell_type_tag(v_metadata_root) = 11) THEN
      RETURN "gw_ledger".result_error(i_context_root,'definition-metadata-required');
    END IF;
    v_next_account := "gw_ledger".account_value_set_definition_metadata(v_account_root,v_symbol_root,v_metadata_root);
    v_next_context := "gw_ledger".replace_current_account(i_context_root,v_next_account,2);
    RETURN "gw_ledger".result_ok(v_next_context,v_metadata_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.account-runtime/apply-primitive [182] 
CREATE OR REPLACE FUNCTION "gw_ledger".apply_primitive(
  i_context_root BYTEA,
  i_primitive_id TEXT,
  i_roots JSONB
) RETURNS JSONB AS $$

  DECLARE
    v_cost BIGINT;
  BEGIN
    v_cost := CASE WHEN (i_primitive_id = 'account/set-key') OR (i_primitive_id = 'account/set-controller') THEN 3
    WHEN i_primitive_id = 'account/set-definition-metadata' THEN 2
    ELSE 1
    END;
    IF NOT "gw_ledger".context_can_charge(i_context_root,v_cost) THEN
      RETURN "gw_ledger".result_error(i_context_root,'cost-limit');
    END IF;
    IF i_primitive_id = 'account/exists' THEN
      RETURN "gw_ledger".apply_account_exists(i_context_root,i_roots);
    ELSIF (i_primitive_id = 'account/root') OR (i_primitive_id = 'account/sequence') OR (i_primitive_id = 'account/key') OR (i_primitive_id = 'account/controller') OR (i_primitive_id = 'account/environment') OR (i_primitive_id = 'account/metadata') THEN
      RETURN "gw_ledger".read_account_field(i_context_root,i_primitive_id,i_roots);
    ELSIF i_primitive_id = 'account/set-key' THEN
      RETURN "gw_ledger".apply_account_set_key(i_context_root,i_roots);
    ELSIF i_primitive_id = 'account/set-controller' THEN
      RETURN "gw_ledger".apply_account_set_controller(i_context_root,i_roots);
    ELSIF i_primitive_id = 'account/set-definition-metadata' THEN
      RETURN "gw_ledger".apply_account_set_definition_metadata(i_context_root,i_roots);
    ELSE
      RETURN "gw_ledger".result_error(i_context_root,'unknown-account-primitive');
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-v2/execute-machine [31] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_machine(
  i_mode TEXT,
  i_context_root BYTEA,
  i_op_root BYTEA,
  i_position INTEGER,
  i_count INTEGER,
  i_roots JSONB,
  i_callable_root BYTEA
) RETURNS JSONB AS $$
BEGIN
  IF i_mode = 'children' THEN
    IF i_position >= i_count THEN
      RETURN "gw_ledger".evaluated_roots(i_context_root,i_roots);
    ELSE
      DECLARE
    o_child JSONB;
        v_next JSONB;
  BEGIN
    o_child := "gw_ledger".execute_machine(
          'eval',
          i_context_root,
          "gw_ledger".op_child_root(i_op_root,i_position),
          0,
          0,
          jsonb_build_array(),
          null
        );
        IF (o_child ->> 'status')::TEXT = 'error' THEN
          RETURN o_child;
        END IF;
        v_next := (i_roots || jsonb_build_array(encode((o_child ->> 'value_root')::BYTEA,'hex')));
        RETURN "gw_ledger".execute_machine(
          'children',
          (o_child ->> 'context_root')::BYTEA,
          i_op_root,
          i_position + 1,
          i_count,
          v_next,
          null
        );
  END;
    END IF;
  ELSIF i_mode = 'condition' THEN
    IF i_position >= i_count THEN
      RETURN "gw_ledger".result_ok(i_context_root,"gw_ledger".put_nil());
    ELSE
      DECLARE
    o_test JSONB;
  BEGIN
    o_test := "gw_ledger".execute_machine(
          'eval',
          i_context_root,
          "gw_ledger".op_child_root(i_op_root,i_position),
          0,
          0,
          jsonb_build_array(),
          null
        );
        IF (o_test ->> 'status')::TEXT = 'error' THEN
          RETURN o_test;
        END IF;
        IF "gw_ledger".truthy((o_test ->> 'value_root')::BYTEA) THEN
          RETURN "gw_ledger".execute_machine(
            'eval',
            (o_test ->> 'context_root')::BYTEA,
            "gw_ledger".op_child_root(i_op_root,i_position + 1),
            0,
            0,
            jsonb_build_array(),
            null
          );
        ELSE
          RETURN "gw_ledger".execute_machine(
            'condition',
            (o_test ->> 'context_root')::BYTEA,
            i_op_root,
            i_position + 2,
            i_count,
            jsonb_build_array(),
            null
          );
        END IF;
  END;
    END IF;
  ELSIF i_mode = 'call' THEN
    DECLARE
    o_function JSONB;
      o_primitive JSONB;
      v_count INTEGER;
  BEGIN
    o_primitive := "gw_ledger".primitive_get_root(i_callable_root);
      o_function := "gw_ledger".function_get(i_callable_root);
      v_count := jsonb_array_length(i_roots);
      IF o_primitive is not null  THEN
        DECLARE
        v_arity INTEGER;
          v_id TEXT;
      BEGIN
        v_arity := (o_primitive ->> 'arity')::INTEGER;
          v_id := (o_primitive ->> 'primitive_id')::TEXT;
          IF NOT (v_arity = -1) AND NOT (v_arity = v_count) THEN
            RETURN "gw_ledger".result_error(i_context_root,'arity');
          END IF;
          RETURN "gw_ledger".apply_primitive(i_context_root,v_id,i_roots);
      END;
      ELSIF o_function is not null  THEN
        DECLARE
        o_body JSONB;
          o_caller JSONB;
          v_call_context BYTEA;
          v_frame_root BYTEA;
          v_parameter_count INTEGER;
          v_restored BYTEA;
      BEGIN
        o_caller := "gw_ledger".context_get(i_context_root);
          IF NOT "gw_ledger".function_valid(i_callable_root) THEN
            RETURN "gw_ledger".result_error(i_context_root,'invalid-function');
          END IF;
          v_parameter_count := "gw_ledger".cell_ref_count((o_function ->> 'parameters_root')::BYTEA,'element');
          IF NOT (v_parameter_count = v_count) THEN
            RETURN "gw_ledger".result_error(i_context_root,'arity');
          END IF;
          IF (o_caller ->> 'depth')::INTEGER >= 64 THEN
            RETURN "gw_ledger".result_error(i_context_root,'max-depth');
          END IF;
          IF NOT "gw_ledger".context_can_charge(i_context_root,2) THEN
            RETURN "gw_ledger".result_error(i_context_root,'cost-limit');
          END IF;
          v_frame_root := "gw_ledger".put_vector(
            i_roots || "gw_ledger".vector_roots((o_function ->> 'closure_root')::BYTEA)
          );
          v_call_context := "gw_ledger".context_charge("gw_ledger".context_with_locals(
            i_context_root,
            v_frame_root,
            (o_caller ->> 'depth')::INTEGER + 1
          ),2);
          o_body := "gw_ledger".execute_machine(
            'eval',
            v_call_context,
            (o_function ->> 'body_root')::BYTEA,
            0,
            0,
            jsonb_build_array(),
            null
          );
          IF (o_body ->> 'status')::TEXT = 'error' THEN
            RETURN o_body;
          END IF;
          v_restored := "gw_ledger".context_with_locals(
            (o_body ->> 'context_root')::BYTEA,
            (o_caller ->> 'locals_root')::BYTEA,
            (o_caller ->> 'depth')::INTEGER
          );
          RETURN "gw_ledger".result_ok(v_restored,(o_body ->> 'value_root')::BYTEA);
      END;
      ELSE
        RETURN "gw_ledger".result_error(i_context_root,'unknown-callable');
      END IF;
  END;
  ELSE
    DECLARE
    o_op JSONB;
      v_kind TEXT;
  BEGIN
    o_op := "gw_ledger".op_get(i_op_root);
      v_kind := CASE WHEN o_op IS NULL THEN ''
      ELSE (o_op ->> 'op_kind')::TEXT
      END;
      IF o_op is null  THEN
        RETURN "gw_ledger".result_error(i_context_root,'unknown-op');
      ELSIF NOT "gw_ledger".op_valid(i_op_root) THEN
        RETURN "gw_ledger".result_error(i_context_root,'invalid-op');
      ELSIF v_kind = 'constant' THEN
        RETURN "gw_ledger".execute_constant(i_context_root,i_op_root);
      ELSIF v_kind = 'special' THEN
        RETURN "gw_ledger".execute_special(i_context_root,i_op_root);
      ELSIF v_kind = 'lookup' THEN
        RETURN "gw_ledger".execute_lookup(i_context_root,i_op_root);
      ELSIF v_kind = 'local' THEN
        RETURN "gw_ledger".execute_local(i_context_root,i_op_root);
      ELSIF v_kind = 'lambda' THEN
        RETURN "gw_ledger".execute_lambda(i_context_root,i_op_root);
      ELSIF v_kind = 'invoke' THEN
        DECLARE
        v_child_count INTEGER;
          v_static_root BYTEA;
      BEGIN
        v_static_root := (o_op ->> 'function_root')::BYTEA;
          v_child_count := "gw_ledger".cell_ref_count(i_op_root,'op-child');
          IF v_static_root is not null  THEN
            DECLARE
            o_arguments JSONB;
          BEGIN
            o_arguments := "gw_ledger".execute_machine(
                'children',
                i_context_root,
                i_op_root,
                0,
                v_child_count,
                jsonb_build_array(),
                null
              );
              IF (o_arguments ->> 'status')::TEXT = 'error' THEN
                RETURN o_arguments;
              END IF;
              RETURN "gw_ledger".execute_machine(
                'call',
                (o_arguments ->> 'context_root')::BYTEA,
                null,
                0,
                0,
                (o_arguments ->> 'roots')::JSONB,
                v_static_root
              );
          END;
          ELSIF v_child_count < 1 THEN
            RETURN "gw_ledger".result_error(i_context_root,'call-requires-callee');
          ELSE
            DECLARE
            o_arguments JSONB;
              o_callee JSONB;
          BEGIN
            o_callee := "gw_ledger".execute_machine(
                'eval',
                i_context_root,
                "gw_ledger".op_child_root(i_op_root,0),
                0,
                0,
                jsonb_build_array(),
                null
              );
              IF (o_callee ->> 'status')::TEXT = 'error' THEN
                RETURN o_callee;
              END IF;
              o_arguments := "gw_ledger".execute_machine(
                'children',
                (o_callee ->> 'context_root')::BYTEA,
                i_op_root,
                1,
                v_child_count,
                jsonb_build_array(),
                null
              );
              IF (o_arguments ->> 'status')::TEXT = 'error' THEN
                RETURN o_arguments;
              END IF;
              RETURN "gw_ledger".execute_machine(
                'call',
                (o_arguments ->> 'context_root')::BYTEA,
                null,
                0,
                0,
                (o_arguments ->> 'roots')::JSONB,
                (o_callee ->> 'value_root')::BYTEA
              );
          END;
          END IF;
      END;
      ELSIF v_kind = 'let' THEN
        DECLARE
        o_binding JSONB;
          o_binding_context JSONB;
          o_body JSONB;
          v_binding_context_root BYTEA;
          v_body_context BYTEA;
          v_frame_root BYTEA;
          v_restored BYTEA;
      BEGIN
        IF NOT ("gw_ledger".cell_ref_count(i_op_root,'op-child') = 2) THEN
            RETURN "gw_ledger".result_error(i_context_root,'let-arity');
          END IF;
          o_binding := "gw_ledger".execute_machine(
            'eval',
            i_context_root,
            "gw_ledger".op_child_root(i_op_root,0),
            0,
            0,
            jsonb_build_array(),
            null
          );
          IF (o_binding ->> 'status')::TEXT = 'error' THEN
            RETURN o_binding;
          END IF;
          v_binding_context_root := (o_binding ->> 'context_root')::BYTEA;
          o_binding_context := "gw_ledger".context_get(v_binding_context_root);
          v_frame_root := "gw_ledger".put_vector(
            "gw_ledger".vector_roots((o_binding_context ->> 'locals_root')::BYTEA) || jsonb_build_array(encode((o_binding ->> 'value_root')::BYTEA,'hex'))
          );
          IF NOT "gw_ledger".context_can_charge(v_binding_context_root,1) THEN
            RETURN "gw_ledger".result_error(v_binding_context_root,'cost-limit');
          END IF;
          v_body_context := "gw_ledger".context_charge("gw_ledger".context_with_locals(
            v_binding_context_root,
            v_frame_root,
            (o_binding_context ->> 'depth')::INTEGER + 1
          ),1);
          o_body := "gw_ledger".execute_machine(
            'eval',
            v_body_context,
            "gw_ledger".op_child_root(i_op_root,1),
            0,
            0,
            jsonb_build_array(),
            null
          );
          IF (o_body ->> 'status')::TEXT = 'error' THEN
            RETURN o_body;
          END IF;
          v_restored := "gw_ledger".context_with_locals(
            (o_body ->> 'context_root')::BYTEA,
            (o_binding_context ->> 'locals_root')::BYTEA,
            (o_binding_context ->> 'depth')::INTEGER
          );
          RETURN "gw_ledger".result_ok(v_restored,(o_body ->> 'value_root')::BYTEA);
      END;
      ELSIF v_kind = 'def' THEN
        DECLARE
        o_value JSONB;
          o_value_context JSONB;
          v_account_root BYTEA;
          v_next_account BYTEA;
          v_next_context BYTEA;
          v_next_state BYTEA;
          v_value_context_root BYTEA;
      BEGIN
        IF NOT ("gw_ledger".cell_ref_count(i_op_root,'op-child') = 1) THEN
            RETURN "gw_ledger".result_error(i_context_root,'def-arity');
          END IF;
          o_value := "gw_ledger".execute_machine(
            'eval',
            i_context_root,
            "gw_ledger".op_child_root(i_op_root,0),
            0,
            0,
            jsonb_build_array(),
            null
          );
          IF (o_value ->> 'status')::TEXT = 'error' THEN
            RETURN o_value;
          END IF;
          v_value_context_root := (o_value ->> 'context_root')::BYTEA;
          o_value_context := "gw_ledger".context_get(v_value_context_root);
          IF NOT "gw_ledger".context_can_charge(v_value_context_root,2) THEN
            RETURN "gw_ledger".result_error(v_value_context_root,'cost-limit');
          END IF;
          v_account_root := "gw_ledger".state_account_root(
            (o_value_context ->> 'state_root')::BYTEA,
            (o_value_context ->> 'address')::BYTEA
          );
          IF v_account_root is null  THEN
            RETURN "gw_ledger".result_error(v_value_context_root,'missing-account');
          END IF;
          v_next_account := "gw_ledger".account_value_define(
            v_account_root,
            (o_op ->> 'symbol_root')::BYTEA,
            (o_value ->> 'value_root')::BYTEA
          );
          v_next_state := "gw_ledger".state_assoc_account(
            (o_value_context ->> 'state_root')::BYTEA,
            (o_value_context ->> 'address')::BYTEA,
            v_next_account,
            (o_value_context ->> 'block_height')::BIGINT
          );
          v_next_context := "gw_ledger".context_charge(
            "gw_ledger".context_with_state(v_value_context_root,v_next_state),
            2
          );
          RETURN "gw_ledger".result_ok(v_next_context,(o_value ->> 'value_root')::BYTEA);
      END;
      ELSIF v_kind = 'cond' THEN
        DECLARE
        v_count INTEGER;
      BEGIN
        v_count := "gw_ledger".cell_ref_count(i_op_root,'op-child');
          IF NOT ((v_count % 2) = 0) THEN
            RETURN "gw_ledger".result_error(i_context_root,'uneven-condition-children');
          ELSE
            RETURN "gw_ledger".execute_machine(
              'condition',
              i_context_root,
              i_op_root,
              0,
              v_count,
              jsonb_build_array(),
              null
            );
          END IF;
      END;
      ELSIF v_kind = 'do' THEN
        DECLARE
        v_count INTEGER;
      BEGIN
        v_count := "gw_ledger".cell_ref_count(i_op_root,'op-child');
          IF v_count = 0 THEN
            RETURN "gw_ledger".result_ok(i_context_root,"gw_ledger".put_nil());
          ELSE
            DECLARE
            o_results JSONB;
          BEGIN
            o_results := "gw_ledger".execute_machine(
                'children',
                i_context_root,
                i_op_root,
                0,
                v_count,
                jsonb_build_array(),
                null
              );
              IF (o_results ->> 'status')::TEXT = 'error' THEN
                RETURN o_results;
              END IF;
              RETURN "gw_ledger".result_ok(
                (o_results ->> 'context_root')::BYTEA,
                "gw_ledger".root_at((o_results ->> 'roots')::JSONB,v_count - 1)
              );
          END;
          END IF;
      END;
      ELSE
        RETURN "gw_ledger".result_error(i_context_root,'unsupported-op');
      END IF;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-v2/execute [315] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$
BEGIN
  RETURN "gw_ledger".execute_machine('eval',i_context_root,i_op_root,0,0,jsonb_build_array(),null);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-profile/field [17] 
CREATE OR REPLACE FUNCTION "gw_ledger".field(
  i_profile_root BYTEA,
  i_name TEXT
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".map_get(i_profile_root,"gw_ledger".put_keyword(i_name));
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-profile/profile-put [24] 
CREATE OR REPLACE FUNCTION "gw_ledger".profile_put(
  i_name_root BYTEA,
  i_version_root BYTEA,
  i_bindings_root BYTEA,
  i_operations_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_bound BYTEA;
    v_named BYTEA;
    v_profile BYTEA;
    v_versioned BYTEA;
  BEGIN
    v_profile := "gw_ledger".map_assoc(
      "gw_ledger".put_map(jsonb_build_array()),
      "gw_ledger".put_keyword('record/type'),
      "gw_ledger".put_keyword('runtime-profile')
    );
    v_named := "gw_ledger".map_assoc(v_profile,"gw_ledger".put_keyword('profile/name'),i_name_root);
    v_versioned := "gw_ledger".map_assoc(
      v_named,
      "gw_ledger".put_keyword('profile/version'),
      i_version_root
    );
    v_bound := "gw_ledger".map_assoc(
      v_versioned,
      "gw_ledger".put_keyword('profile/bindings'),
      i_bindings_root
    );
    RETURN "gw_ledger".map_assoc(
      v_bound,
      "gw_ledger".put_keyword('profile/operations'),
      i_operations_root
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-profile/profile-valid [48] 
CREATE OR REPLACE FUNCTION "gw_ledger".profile_valid(
  i_profile_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_profile JSONB;
    v_bindings_root BYTEA;
    v_name_root BYTEA;
    v_operations_root BYTEA;
    v_type_root BYTEA;
    v_version_root BYTEA;
  BEGIN
    o_profile := "gw_ledger".cell_by_hash(i_profile_root);
    IF o_profile IS NULL OR NOT ((o_profile ->> 'type_tag')::SMALLINT = 11) THEN
      RETURN false;
    END IF;
    v_type_root := "gw_ledger".field(i_profile_root,'record/type');
    v_name_root := "gw_ledger".field(i_profile_root,'profile/name');
    v_version_root := "gw_ledger".field(i_profile_root,'profile/version');
    v_bindings_root := "gw_ledger".field(i_profile_root,'profile/bindings');
    v_operations_root := "gw_ledger".field(i_profile_root,'profile/operations');
    RETURN (v_type_root = "gw_ledger".put_keyword('runtime-profile')) AND ("gw_ledger".cell_type_tag(v_name_root) = 7) AND ("gw_ledger".cell_type_tag(v_version_root) = 2) AND ("gw_ledger".cell_type_tag(v_bindings_root) = 11) AND ("gw_ledger".cell_type_tag(v_operations_root) = 11);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-profile/runtime-root-valid [68] 
CREATE OR REPLACE FUNCTION "gw_ledger".runtime_root_valid(
  i_runtime_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_runtime JSONB;
  BEGIN
    o_runtime := "gw_ledger".cell_by_hash(i_runtime_root);
    RETURN (o_runtime IS NOT NULL AND ((o_runtime ->> 'type_tag')::SMALLINT = 2) AND ("gw_ledger".integer_bigint(i_runtime_root) = 1)) OR "gw_ledger".profile_valid(i_runtime_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-profile/profile-lookup [80] 
CREATE OR REPLACE FUNCTION "gw_ledger".profile_lookup(
  i_profile_root BYTEA,
  i_symbol_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_bindings_root BYTEA;
  BEGIN
    IF NOT "gw_ledger".profile_valid(i_profile_root) THEN
      RETURN null;
    END IF;
    v_bindings_root := "gw_ledger".field(i_profile_root,'profile/bindings');
    RETURN "gw_ledger".map_get(v_bindings_root,i_symbol_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-profile/binding-assoc [91] 
CREATE OR REPLACE FUNCTION "gw_ledger".binding_assoc(
  i_bindings_root BYTEA,
  i_symbol TEXT,
  i_primitive_id TEXT,
  i_arity INTEGER
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".map_assoc(
    i_bindings_root,
    "gw_ledger".put_symbol(i_symbol),
    "gw_ledger".primitive_put(i_primitive_id,i_arity)
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-profile/operation-assoc [102] 
CREATE OR REPLACE FUNCTION "gw_ledger".operation_assoc(
  i_operations_root BYTEA,
  i_symbol TEXT,
  i_operation TEXT
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".map_assoc(
    i_operations_root,
    "gw_ledger".put_symbol(i_symbol),
    "gw_ledger".put_symbol(i_operation)
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.runtime-profile/convex-profile-put [112] 
CREATE OR REPLACE FUNCTION "gw_ledger".convex_profile_put() RETURNS BYTEA AS $$

  DECLARE
    v_bindings_0 BYTEA;
    v_bindings_1 BYTEA;
    v_bindings_10 BYTEA;
    v_bindings_11 BYTEA;
    v_bindings_12 BYTEA;
    v_bindings_13 BYTEA;
    v_bindings_2 BYTEA;
    v_bindings_3 BYTEA;
    v_bindings_4 BYTEA;
    v_bindings_5 BYTEA;
    v_bindings_6 BYTEA;
    v_bindings_7 BYTEA;
    v_bindings_8 BYTEA;
    v_bindings_9 BYTEA;
    v_operations_0 BYTEA;
    v_operations_1 BYTEA;
    v_operations_2 BYTEA;
    v_operations_3 BYTEA;
  BEGIN
    v_bindings_0 := "gw_ledger".put_map(jsonb_build_array());
    v_bindings_1 := "gw_ledger".binding_assoc(v_bindings_0,'+','integer/add',2);
    v_bindings_2 := "gw_ledger".binding_assoc(v_bindings_1,'-','integer/subtract',2);
    v_bindings_3 := "gw_ledger".binding_assoc(v_bindings_2,'*','integer/multiply',2);
    v_bindings_4 := "gw_ledger".binding_assoc(v_bindings_3,'=','value/equal',2);
    v_bindings_5 := "gw_ledger".binding_assoc(v_bindings_4,'not','boolean/not',1);
    v_bindings_6 := "gw_ledger".binding_assoc(v_bindings_5,'vector','vector/new',-1);
    v_bindings_7 := "gw_ledger".binding_assoc(v_bindings_6,'count','vector/count',1);
    v_bindings_8 := "gw_ledger".binding_assoc(v_bindings_7,'get','map/get',2);
    v_bindings_9 := "gw_ledger".binding_assoc(v_bindings_8,'assoc','map/assoc',3);
    v_bindings_10 := "gw_ledger".binding_assoc(v_bindings_9,'str','string/concat',-1);
    v_bindings_11 := "gw_ledger".binding_assoc(v_bindings_10,'account','account/root',1);
    v_bindings_12 := "gw_ledger".binding_assoc(v_bindings_11,'account-key','account/key',1);
    v_bindings_13 := "gw_ledger".binding_assoc(v_bindings_12,'account-controller','account/controller',1);
    v_operations_0 := "gw_ledger".put_map(jsonb_build_array());
    v_operations_1 := "gw_ledger".operation_assoc(v_operations_0,'deploy','ignatius.op/actor-deploy');
    v_operations_2 := "gw_ledger".operation_assoc(v_operations_1,'call','ignatius.op/actor-call');
    v_operations_3 := "gw_ledger".operation_assoc(v_operations_2,'query','ignatius.op/actor-query');
    RETURN "gw_ledger".profile_put(
      "gw_ledger".put_symbol('convex.compat'),
      "gw_ledger".put_integer('1'),
      v_bindings_13,
      v_operations_3
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/keyword-root [29] 
CREATE OR REPLACE FUNCTION "gw_ledger".keyword_root(
  i_name TEXT
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_keyword(i_name);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/field [35] 
CREATE OR REPLACE FUNCTION "gw_ledger".field(
  i_record_root BYTEA,
  i_name TEXT
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".map_get(i_record_root,"gw_ledger".keyword_root(i_name));
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/record-start [42] 
CREATE OR REPLACE FUNCTION "gw_ledger".record_start(
  i_kind TEXT
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".map_assoc(
    "gw_ledger".put_map(jsonb_build_array()),
    "gw_ledger".keyword_root('record/type'),
    "gw_ledger".keyword_root(i_kind)
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/record-assoc [52] 
CREATE OR REPLACE FUNCTION "gw_ledger".record_assoc(
  i_record_root BYTEA,
  i_name TEXT,
  i_value_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".map_assoc(i_record_root,"gw_ledger".keyword_root(i_name),i_value_root);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/record-kind [60] 
CREATE OR REPLACE FUNCTION "gw_ledger".record_kind(
  i_record_root BYTEA,
  i_kind TEXT
) RETURNS BOOLEAN AS $$

  DECLARE
    o_cell JSONB;
  BEGIN
    o_cell := "gw_ledger".cell_by_hash(i_record_root);
    RETURN o_cell IS NOT NULL AND ((o_cell ->> 'type_tag')::SMALLINT = 11) AND ("gw_ledger".field(i_record_root,'record/type') = "gw_ledger".keyword_root(i_kind));
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/optional-root [71] 
CREATE OR REPLACE FUNCTION "gw_ledger".optional_root(
  i_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN CASE WHEN i_root IS NULL THEN "gw_ledger".put_nil()
  ELSE i_root
  END;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/function-arity [80] 
CREATE OR REPLACE FUNCTION "gw_ledger".function_arity(
  i_function_root BYTEA,
  i_arity INTEGER
) RETURNS BOOLEAN AS $$

  DECLARE
    o_function JSONB;
  BEGIN
    o_function := "gw_ledger".function_get(i_function_root);
    RETURN o_function IS NOT NULL AND "gw_ledger".function_valid(i_function_root) AND ("gw_ledger".cell_ref_count((o_function ->> 'parameters_root')::BYTEA,'element') = i_arity);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/views-valid-at [93] 
CREATE OR REPLACE FUNCTION "gw_ledger".views_valid_at(
  i_views_root BYTEA,
  i_position INTEGER,
  i_count INTEGER
) RETURNS BOOLEAN AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN true;
  ELSE
    DECLARE
    v_function_root BYTEA;
      v_name_root BYTEA;
  BEGIN
    v_name_root := "gw_ledger".cell_ref_child(i_views_root,i_position,'key');
      v_function_root := "gw_ledger".cell_ref_child(i_views_root,i_position,'value');
      RETURN ("gw_ledger".cell_type_tag(v_name_root) = 7) AND "gw_ledger".function_arity(v_function_root,1) AND "gw_ledger".views_valid_at(i_views_root,i_position + 1,i_count);
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/views-valid [110] 
CREATE OR REPLACE FUNCTION "gw_ledger".views_valid(
  i_views_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_views JSONB;
  BEGIN
    o_views := "gw_ledger".cell_by_hash(i_views_root);
    RETURN o_views IS NOT NULL AND ((o_views ->> 'type_tag')::SMALLINT = 11) AND "gw_ledger".views_valid_at(i_views_root,0,"gw_ledger".cell_ref_count(i_views_root,'key'));
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/template-put [122] 
CREATE OR REPLACE FUNCTION "gw_ledger".template_put(
  i_name_root BYTEA,
  i_version_root BYTEA,
  i_publisher_root BYTEA,
  i_init_root BYTEA,
  i_transition_root BYTEA,
  i_views_root BYTEA,
  i_source_root BYTEA,
  i_compiler_root BYTEA,
  i_runtime_root BYTEA,
  i_event_schema_root BYTEA,
  i_state_schema_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_compiler BYTEA;
    v_event_schema BYTEA;
    v_init BYTEA;
    v_name BYTEA;
    v_publisher BYTEA;
    v_record BYTEA;
    v_runtime BYTEA;
    v_source BYTEA;
    v_transition BYTEA;
    v_version BYTEA;
    v_views BYTEA;
  BEGIN
    IF NOT ("gw_ledger".cell_type_tag(i_name_root) = 7) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/contract_name_not_symbol',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/contract-name-not-symbol'
      ;
    END IF;
    IF NOT ("gw_ledger".cell_by_hash(i_version_root) IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_contract_version',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-contract-version'
      ;
    END IF;
    IF NOT ("gw_ledger".cell_by_hash(i_publisher_root) IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_contract_publisher',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-contract-publisher'
      ;
    END IF;
    IF NOT ("gw_ledger".function_arity(i_init_root,1)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_contract_init',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-contract-init'
      ;
    END IF;
    IF NOT ("gw_ledger".function_arity(i_transition_root,2)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_contract_transition',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-contract-transition'
      ;
    END IF;
    IF NOT ("gw_ledger".views_valid(i_views_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_contract_views',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-contract-views'
      ;
    END IF;
    IF NOT ("gw_ledger".cell_by_hash(i_source_root) IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_contract_source',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-contract-source'
      ;
    END IF;
    IF NOT ("gw_ledger".cell_by_hash(i_compiler_root) IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_contract_compiler',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-contract-compiler'
      ;
    END IF;
    IF NOT ("gw_ledger".runtime_root_valid(i_runtime_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_contract_runtime',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-contract-runtime'
      ;
    END IF;
    IF NOT ("gw_ledger".cell_by_hash(i_event_schema_root) IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_contract_event_schema',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-contract-event-schema'
      ;
    END IF;
    IF NOT ("gw_ledger".cell_by_hash(i_state_schema_root) IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/missing_contract_state_schema',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/missing-contract-state-schema'
      ;
    END IF;
    v_record := "gw_ledger".record_start('contract-template');
    v_name := "gw_ledger".record_assoc(v_record,'contract/name',i_name_root);
    v_version := "gw_ledger".record_assoc(v_name,'contract/version',i_version_root);
    v_publisher := "gw_ledger".record_assoc(v_version,'contract/publisher',i_publisher_root);
    v_init := "gw_ledger".record_assoc(v_publisher,'contract/init',i_init_root);
    v_transition := "gw_ledger".record_assoc(v_init,'contract/transition',i_transition_root);
    v_views := "gw_ledger".record_assoc(v_transition,'contract/views',i_views_root);
    v_source := "gw_ledger".record_assoc(v_views,'contract/source',i_source_root);
    v_compiler := "gw_ledger".record_assoc(v_source,'contract/compiler',i_compiler_root);
    v_runtime := "gw_ledger".record_assoc(v_compiler,'contract/runtime',i_runtime_root);
    v_event_schema := "gw_ledger".record_assoc(v_runtime,'contract/event-schema',i_event_schema_root);
    RETURN "gw_ledger".record_assoc(v_event_schema,'contract/state-schema',i_state_schema_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/template-valid [185] 
CREATE OR REPLACE FUNCTION "gw_ledger".template_valid(
  i_template_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    v_compiler_root BYTEA;
    v_event_schema_root BYTEA;
    v_init_root BYTEA;
    v_name_root BYTEA;
    v_publisher_root BYTEA;
    v_runtime_root BYTEA;
    v_source_root BYTEA;
    v_state_schema_root BYTEA;
    v_transition_root BYTEA;
    v_views_root BYTEA;
  BEGIN
    IF NOT "gw_ledger".record_kind(i_template_root,'contract-template') THEN
      RETURN false;
    END IF;
    v_name_root := "gw_ledger".field(i_template_root,'contract/name');
    v_publisher_root := "gw_ledger".field(i_template_root,'contract/publisher');
    v_init_root := "gw_ledger".field(i_template_root,'contract/init');
    v_transition_root := "gw_ledger".field(i_template_root,'contract/transition');
    v_views_root := "gw_ledger".field(i_template_root,'contract/views');
    v_source_root := "gw_ledger".field(i_template_root,'contract/source');
    v_compiler_root := "gw_ledger".field(i_template_root,'contract/compiler');
    v_runtime_root := "gw_ledger".field(i_template_root,'contract/runtime');
    v_event_schema_root := "gw_ledger".field(i_template_root,'contract/event-schema');
    v_state_schema_root := "gw_ledger".field(i_template_root,'contract/state-schema');
    RETURN ("gw_ledger".cell_type_tag(v_name_root) = 7) AND "gw_ledger".cell_by_hash(v_publisher_root) IS NOT NULL AND "gw_ledger".function_arity(v_init_root,1) AND "gw_ledger".function_arity(v_transition_root,2) AND "gw_ledger".views_valid(v_views_root) AND "gw_ledger".cell_by_hash(v_source_root) IS NOT NULL AND "gw_ledger".cell_by_hash(v_compiler_root) IS NOT NULL AND "gw_ledger".runtime_root_valid(v_runtime_root) AND "gw_ledger".cell_by_hash(v_event_schema_root) IS NOT NULL AND "gw_ledger".cell_by_hash(v_state_schema_root) IS NOT NULL;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/publication-put [224] 
CREATE OR REPLACE FUNCTION "gw_ledger".publication_put(
  i_template_root BYTEA,
  i_publisher_root BYTEA,
  i_alias_root BYTEA,
  i_transaction_root BYTEA,
  i_timestamp BIGINT
) RETURNS BYTEA AS $$

  DECLARE
    v_alias BYTEA;
    v_publisher BYTEA;
    v_record BYTEA;
    v_template BYTEA;
    v_transaction BYTEA;
  BEGIN
    IF NOT ("gw_ledger".template_valid(i_template_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_contract_template',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-contract-template'
      ;
    END IF;
    IF NOT ("gw_ledger".cell_type_tag(i_alias_root) = 7) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/contract_alias_not_symbol',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/contract-alias-not-symbol'
      ;
    END IF;
    v_record := "gw_ledger".record_start('contract-publication');
    v_template := "gw_ledger".record_assoc(v_record,'contract/template',i_template_root);
    v_publisher := "gw_ledger".record_assoc(v_template,'contract/publisher',i_publisher_root);
    v_alias := "gw_ledger".record_assoc(v_publisher,'contract/alias',i_alias_root);
    v_transaction := "gw_ledger".record_assoc(
      v_alias,
      'contract/transaction',
      "gw_ledger".optional_root(i_transaction_root)
    );
    RETURN "gw_ledger".record_assoc(
      v_transaction,
      'contract/timestamp',
      "gw_ledger".put_integer_number(i_timestamp)
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/verified-event-put [253] 
CREATE OR REPLACE FUNCTION "gw_ledger".verified_event_put(
  i_payload_root BYTEA,
  i_contract_root BYTEA,
  i_template_root BYTEA,
  i_signer_root BYTEA,
  i_transaction_root BYTEA,
  i_timestamp BIGINT,
  i_previous_head_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_contract BYTEA;
    v_signer BYTEA;
    v_template BYTEA;
    v_timestamp BYTEA;
    v_transaction BYTEA;
  BEGIN
    IF NOT ("gw_ledger".cell_type_tag(i_payload_root) = 11) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/contract_event_not_map',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/contract-event-not-map'
      ;
    END IF;
    v_contract := "gw_ledger".map_assoc(
      i_payload_root,
      "gw_ledger".keyword_root('contract'),
      i_contract_root
    );
    v_template := "gw_ledger".map_assoc(
      v_contract,
      "gw_ledger".keyword_root('template'),
      i_template_root
    );
    v_signer := "gw_ledger".map_assoc(v_template,"gw_ledger".keyword_root('signer'),i_signer_root);
    v_transaction := "gw_ledger".map_assoc(
      v_signer,
      "gw_ledger".keyword_root('transaction'),
      "gw_ledger".optional_root(i_transaction_root)
    );
    v_timestamp := "gw_ledger".map_assoc(
      v_transaction,
      "gw_ledger".keyword_root('timestamp'),
      "gw_ledger".put_integer_number(i_timestamp)
    );
    RETURN "gw_ledger".map_assoc(
      v_timestamp,
      "gw_ledger".keyword_root('previous-head'),
      i_previous_head_root
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/commit-put [288] 
CREATE OR REPLACE FUNCTION "gw_ledger".commit_put(
  i_contract_root BYTEA,
  i_template_root BYTEA,
  i_parent_root BYTEA,
  i_event_root BYTEA,
  i_signer_root BYTEA,
  i_previous_state_root BYTEA,
  i_state_root BYTEA,
  i_transaction_root BYTEA,
  i_timestamp BIGINT
) RETURNS BYTEA AS $$

  DECLARE
    v_after BYTEA;
    v_before BYTEA;
    v_contract BYTEA;
    v_event BYTEA;
    v_parent BYTEA;
    v_record BYTEA;
    v_signer BYTEA;
    v_template BYTEA;
    v_transaction BYTEA;
  BEGIN
    v_record := "gw_ledger".record_start('contract-commit');
    v_contract := "gw_ledger".record_assoc(v_record,'contract/address',i_contract_root);
    v_template := "gw_ledger".record_assoc(v_contract,'contract/template',i_template_root);
    v_parent := "gw_ledger".record_assoc(v_template,'contract/parent',i_parent_root);
    v_event := "gw_ledger".record_assoc(v_parent,'contract/event',i_event_root);
    v_signer := "gw_ledger".record_assoc(v_event,'contract/signer',i_signer_root);
    v_before := "gw_ledger".record_assoc(v_signer,'contract/previous-state',i_previous_state_root);
    v_after := "gw_ledger".record_assoc(v_before,'contract/state',i_state_root);
    v_transaction := "gw_ledger".record_assoc(
      v_after,
      'contract/transaction',
      "gw_ledger".optional_root(i_transaction_root)
    );
    RETURN "gw_ledger".record_assoc(
      v_transaction,
      'contract/timestamp',
      "gw_ledger".put_integer_number(i_timestamp)
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/result-put [325] 
CREATE OR REPLACE FUNCTION "gw_ledger".result_put(
  i_contract_root BYTEA,
  i_head_root BYTEA,
  i_state_root BYTEA,
  i_result_root BYTEA,
  i_committed BOOLEAN
) RETURNS BYTEA AS $$

  DECLARE
    v_contract BYTEA;
    v_head BYTEA;
    v_record BYTEA;
    v_result BYTEA;
    v_state BYTEA;
  BEGIN
    v_record := "gw_ledger".record_start('contract-result');
    v_contract := "gw_ledger".record_assoc(v_record,'contract/address',i_contract_root);
    v_head := "gw_ledger".record_assoc(v_contract,'contract/head',i_head_root);
    v_state := "gw_ledger".record_assoc(v_head,'contract/state',i_state_root);
    v_result := "gw_ledger".record_assoc(v_state,'contract/result',i_result_root);
    RETURN "gw_ledger".record_assoc(
      v_result,
      'contract/committed',
      "gw_ledger".put_boolean(i_committed)
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/template-symbol [347] 
CREATE OR REPLACE FUNCTION "gw_ledger".template_symbol() RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_symbol('ignatius.contract/template');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/state-symbol [353] 
CREATE OR REPLACE FUNCTION "gw_ledger".state_symbol() RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_symbol('ignatius.contract/state');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/head-symbol [359] 
CREATE OR REPLACE FUNCTION "gw_ledger".head_symbol() RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_symbol('ignatius.contract/head');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/history-symbol [365] 
CREATE OR REPLACE FUNCTION "gw_ledger".history_symbol() RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_symbol('ignatius.contract/history');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/creator-symbol [371] 
CREATE OR REPLACE FUNCTION "gw_ledger".creator_symbol() RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_symbol('ignatius.contract/creator');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/instance-account-create [377] 
CREATE OR REPLACE FUNCTION "gw_ledger".instance_account_create(
  i_creator_root BYTEA,
  i_template_root BYTEA,
  i_state_root BYTEA,
  i_head_root BYTEA,
  i_history_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_account BYTEA;
    v_head BYTEA;
    v_history BYTEA;
    v_state BYTEA;
    v_template BYTEA;
  BEGIN
    v_account := "gw_ledger".account_value_create_actor(i_creator_root,i_creator_root);
    v_template := "gw_ledger".account_value_define(v_account,"gw_ledger".template_symbol(),i_template_root);
    v_state := "gw_ledger".account_value_define(v_template,"gw_ledger".state_symbol(),i_state_root);
    v_head := "gw_ledger".account_value_define(v_state,"gw_ledger".head_symbol(),i_head_root);
    v_history := "gw_ledger".account_value_define(v_head,"gw_ledger".history_symbol(),i_history_root);
    RETURN "gw_ledger".account_value_define(v_history,"gw_ledger".creator_symbol(),i_creator_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/instance-account-update [404] 
CREATE OR REPLACE FUNCTION "gw_ledger".instance_account_update(
  i_account_root BYTEA,
  i_state_root BYTEA,
  i_head_root BYTEA,
  i_history_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_head BYTEA;
    v_state BYTEA;
  BEGIN
    v_state := "gw_ledger".account_value_define(i_account_root,"gw_ledger".state_symbol(),i_state_root);
    v_head := "gw_ledger".account_value_define(v_state,"gw_ledger".head_symbol(),i_head_root);
    RETURN "gw_ledger".account_value_define(v_head,"gw_ledger".history_symbol(),i_history_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/instance-binding [421] 
CREATE OR REPLACE FUNCTION "gw_ledger".instance_binding(
  i_state_root BYTEA,
  i_address_root BYTEA,
  i_symbol_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_account_root BYTEA;
  BEGIN
    v_account_root := "gw_ledger".state_account_root(i_state_root,i_address_root);
    RETURN CASE WHEN v_account_root IS NULL THEN null
    ELSE "gw_ledger".account_value_lookup(v_account_root,i_symbol_root)
    END;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/instance-template [433] 
CREATE OR REPLACE FUNCTION "gw_ledger".instance_template(
  i_state_root BYTEA,
  i_address_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".instance_binding(i_state_root,i_address_root,"gw_ledger".template_symbol());
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/instance-state [441] 
CREATE OR REPLACE FUNCTION "gw_ledger".instance_state(
  i_state_root BYTEA,
  i_address_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".instance_binding(i_state_root,i_address_root,"gw_ledger".state_symbol());
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/instance-head [449] 
CREATE OR REPLACE FUNCTION "gw_ledger".instance_head(
  i_state_root BYTEA,
  i_address_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".instance_binding(i_state_root,i_address_root,"gw_ledger".head_symbol());
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/instance-history [457] 
CREATE OR REPLACE FUNCTION "gw_ledger".instance_history(
  i_state_root BYTEA,
  i_address_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".instance_binding(i_state_root,i_address_root,"gw_ledger".history_symbol());
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/instance-valid [465] 
CREATE OR REPLACE FUNCTION "gw_ledger".instance_valid(
  i_state_root BYTEA,
  i_address_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_history JSONB;
    v_contract_state BYTEA;
    v_head_root BYTEA;
    v_history_root BYTEA;
    v_template_root BYTEA;
  BEGIN
    v_template_root := "gw_ledger".instance_template(i_state_root,i_address_root);
    v_contract_state := "gw_ledger".instance_state(i_state_root,i_address_root);
    v_head_root := "gw_ledger".instance_head(i_state_root,i_address_root);
    v_history_root := "gw_ledger".instance_history(i_state_root,i_address_root);
    o_history := "gw_ledger".cell_by_hash(v_history_root);
    RETURN v_template_root IS NOT NULL AND v_contract_state IS NOT NULL AND v_head_root IS NOT NULL AND o_history IS NOT NULL AND "gw_ledger".template_valid(v_template_root) AND "gw_ledger".cell_by_hash(v_contract_state) IS NOT NULL AND "gw_ledger".cell_by_hash(v_head_root) IS NOT NULL AND ((o_history ->> 'type_tag')::SMALLINT = 10);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/root-hex [488] 
CREATE OR REPLACE FUNCTION "gw_ledger".root_hex(
  i_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN CASE WHEN i_root IS NULL THEN '-'
  ELSE encode(i_root,'hex')
  END;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/address-payload [496] 
CREATE OR REPLACE FUNCTION "gw_ledger".address_payload(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_context JSONB;
  BEGIN
    o_context := "gw_ledger".context_get(i_context_root);
    RETURN decode(
      'R:contract-address:1:4:' || "gw_ledger".root_hex((o_context ->> 'transaction_root')::BYTEA) || ':' || "gw_ledger".root_hex((o_context ->> 'address')::BYTEA) || ':' || "gw_ledger".root_hex(i_op_root) || ':' || ((o_context ->> 'cost_used')::BIGINT)::TEXT,
      'escape'
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/address-root [512] 
CREATE OR REPLACE FUNCTION "gw_ledger".address_root(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_blob(
    "gw_ledger".canonical_hash(14,"gw_ledger".address_payload(i_context_root,i_op_root))
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/special-name [521] 
CREATE OR REPLACE FUNCTION "gw_ledger".special_name(
  i_op_root BYTEA
) RETURNS TEXT AS $$

  DECLARE
    o_op JSONB;
    o_symbol JSONB;
  BEGIN
    o_op := "gw_ledger".op_get(i_op_root);
    o_symbol := CASE WHEN o_op IS NULL THEN null
    ELSE "gw_ledger".cell_by_hash((o_op ->> 'symbol_root')::BYTEA)
    END;
    RETURN CASE WHEN o_op IS NULL OR o_symbol IS NULL THEN ''
    ELSE encode((o_symbol ->> 'payload')::BYTEA,'escape')
    END;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/publish-op [538] 
CREATE OR REPLACE FUNCTION "gw_ledger".publish_op(
  i_template_op_root BYTEA,
  i_alias_op_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_op('special',null,"gw_ledger".put_symbol('contract/publish'),null,null,null,null,null,jsonb_build_array(
    encode(i_template_op_root,'hex'),
    encode(i_alias_op_root,'hex')
  ));
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/open-op [550] 
CREATE OR REPLACE FUNCTION "gw_ledger".open_op(
  i_template_op_root BYTEA,
  i_parameters_op_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_op('special',null,"gw_ledger".put_symbol('contract/open'),null,null,null,null,null,jsonb_build_array(
    encode(i_template_op_root,'hex'),
    encode(i_parameters_op_root,'hex')
  ));
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/apply-op [562] 
CREATE OR REPLACE FUNCTION "gw_ledger".apply_op(
  i_contract_op_root BYTEA,
  i_expected_head_op_root BYTEA,
  i_event_op_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_op('special',null,"gw_ledger".put_symbol('contract/apply'),null,null,null,null,null,jsonb_build_array(
    encode(i_contract_op_root,'hex'),
    encode(i_expected_head_op_root,'hex'),
    encode(i_event_op_root,'hex')
  ));
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/simulate-op [577] 
CREATE OR REPLACE FUNCTION "gw_ledger".simulate_op(
  i_contract_op_root BYTEA,
  i_event_op_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_op('special',null,"gw_ledger".put_symbol('contract/simulate'),null,null,null,null,null,jsonb_build_array(
    encode(i_contract_op_root,'hex'),
    encode(i_event_op_root,'hex')
  ));
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/state-op [589] 
CREATE OR REPLACE FUNCTION "gw_ledger".state_op(
  i_contract_op_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_op(
    'special',
    null,
    "gw_ledger".put_symbol('contract/state'),
    null,
    null,
    null,
    null,
    null,
    jsonb_build_array(encode(i_contract_op_root,'hex'))
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/history-op [600] 
CREATE OR REPLACE FUNCTION "gw_ledger".history_op(
  i_contract_op_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_op(
    'special',
    null,
    "gw_ledger".put_symbol('contract/history'),
    null,
    null,
    null,
    null,
    null,
    jsonb_build_array(encode(i_contract_op_root,'hex'))
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract/view-op [611] 
CREATE OR REPLACE FUNCTION "gw_ledger".view_op(
  i_contract_op_root BYTEA,
  i_view_symbol_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_op(
    'special',
    i_view_symbol_root,
    "gw_ledger".put_symbol('contract/view'),
    null,
    null,
    null,
    null,
    null,
    jsonb_build_array(encode(i_contract_op_root,'hex'))
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.actor-runtime/actor-special [33] 
CREATE OR REPLACE FUNCTION "gw_ledger".actor_special(
  i_op_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    v_special TEXT;
  BEGIN
    v_special := "gw_ledger".special_name(i_op_root);
    RETURN (v_special = 'actor/deploy') OR (v_special = 'actor/call') OR (v_special = 'actor/query');
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.actor-runtime/evaluated-roots [43] 
CREATE OR REPLACE FUNCTION "gw_ledger".evaluated_roots(
  i_context_root BYTEA,
  i_roots JSONB
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
      'roots',
      i_roots,
      'cost_used',
      (o_context ->> 'cost_used')::BIGINT
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.actor-runtime/evaluate-children-at [53] 
CREATE OR REPLACE FUNCTION "gw_ledger".evaluate_children_at(
  i_context_root BYTEA,
  i_op_root BYTEA,
  i_position INTEGER,
  i_count INTEGER,
  i_roots JSONB
) RETURNS JSONB AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN "gw_ledger".evaluated_roots(i_context_root,i_roots);
  ELSE
    DECLARE
    o_result JSONB;
      v_next_roots JSONB;
  BEGIN
    o_result := "gw_ledger".execute(
        i_context_root,
        "gw_ledger".op_child_root(i_op_root,i_position)
      );
      IF (o_result ->> 'status')::TEXT = 'error' THEN
        RETURN o_result;
      END IF;
      v_next_roots := (i_roots || jsonb_build_array(encode((o_result ->> 'value_root')::BYTEA,'hex')));
      RETURN "gw_ledger".evaluate_children_at(
        (o_result ->> 'context_root')::BYTEA,
        i_op_root,
        i_position + 1,
        i_count,
        v_next_roots
      );
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.actor-runtime/callables-valid-at [78] 
CREATE OR REPLACE FUNCTION "gw_ledger".callables_valid_at(
  i_state_root BYTEA,
  i_address_root BYTEA,
  i_callables_root BYTEA,
  i_position INTEGER,
  i_count INTEGER
) RETURNS BOOLEAN AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN true;
  ELSE
    DECLARE
    v_account_root BYTEA;
      v_function_root BYTEA;
      v_symbol_root BYTEA;
  BEGIN
    v_account_root := "gw_ledger".state_account_root(i_state_root,i_address_root);
      v_symbol_root := "gw_ledger".vector_get(i_callables_root,i_position);
      v_function_root := CASE WHEN v_account_root IS NULL THEN null
      ELSE "gw_ledger".account_value_lookup(v_account_root,v_symbol_root)
      END;
      RETURN v_account_root IS NOT NULL AND ("gw_ledger".cell_type_tag(v_symbol_root) = 7) AND "gw_ledger".function_valid(v_function_root) AND "gw_ledger".callables_valid_at(
        i_state_root,
        i_address_root,
        i_callables_root,
        i_position + 1,
        i_count
      );
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.actor-runtime/mark-callables-at [103] 
CREATE OR REPLACE FUNCTION "gw_ledger".mark_callables_at(
  i_state_root BYTEA,
  i_address_root BYTEA,
  i_callables_root BYTEA,
  i_position INTEGER,
  i_count INTEGER,
  i_block_height BIGINT
) RETURNS BYTEA AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN i_state_root;
  ELSE
    DECLARE
    v_account_root BYTEA;
      v_next_account BYTEA;
      v_next_state BYTEA;
      v_symbol_root BYTEA;
  BEGIN
    v_account_root := "gw_ledger".state_account_root(i_state_root,i_address_root);
      v_symbol_root := "gw_ledger".vector_get(i_callables_root,i_position);
      v_next_account := "gw_ledger".account_value_set_definition_metadata(v_account_root,v_symbol_root,"gw_ledger".callable_metadata());
      v_next_state := "gw_ledger".state_assoc_account(i_state_root,i_address_root,v_next_account,i_block_height);
      RETURN "gw_ledger".mark_callables_at(
        v_next_state,
        i_address_root,
        i_callables_root,
        i_position + 1,
        i_count,
        i_block_height
      );
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.actor-runtime/execute-deploy [128] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_deploy(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_caller JSONB;
    o_initialized JSONB;
    o_initialized_context JSONB;
    o_op JSONB;
    v_actor_address BYTEA;
    v_actor_context BYTEA;
    v_callable_count INTEGER;
    v_callables_root BYTEA;
    v_charged_context BYTEA;
    v_child_count INTEGER;
    v_deploy_state BYTEA;
    v_initialized_context_root BYTEA;
    v_initialized_state BYTEA;
    v_marked_context BYTEA;
    v_marked_state BYTEA;
    v_restored BYTEA;
  BEGIN
    o_op := "gw_ledger".op_get(i_op_root);
    v_child_count := "gw_ledger".cell_ref_count(i_op_root,'op-child');
    IF NOT (v_child_count = 1) THEN
      RETURN "gw_ledger".result_error(i_context_root,'actor/deploy-arity');
    END IF;
    v_callables_root := (o_op ->> 'value_root')::BYTEA;
    IF NOT ("gw_ledger".cell_type_tag(v_callables_root) = 10) THEN
      RETURN "gw_ledger".result_error(i_context_root,'actor/callables-vector-required');
    END IF;
    IF NOT "gw_ledger".context_can_charge(i_context_root,5) THEN
      RETURN "gw_ledger".result_error(i_context_root,'cost-limit');
    END IF;
    o_caller := "gw_ledger".context_get(i_context_root);
    v_actor_address := "gw_ledger".actor_address_root(i_context_root,i_op_root);
    v_charged_context := "gw_ledger".context_charge(i_context_root,5);
    v_deploy_state := "gw_ledger".deploy_state(v_charged_context,v_actor_address);
    v_actor_context := "gw_ledger".context_enter(
      v_charged_context,
      v_deploy_state,
      v_actor_address,
      (o_caller ->> 'address')::BYTEA
    );
    o_initialized := "gw_ledger".execute(v_actor_context,"gw_ledger".op_child_root(i_op_root,0));
    IF (o_initialized ->> 'status')::TEXT = 'error' THEN
      RETURN o_initialized;
    END IF;
    v_initialized_context_root := (o_initialized ->> 'context_root')::BYTEA;
    o_initialized_context := "gw_ledger".context_get(v_initialized_context_root);
    v_initialized_state := (o_initialized_context ->> 'state_root')::BYTEA;
    v_callable_count := "gw_ledger".cell_ref_count(v_callables_root,'element');
    IF NOT "gw_ledger".callables_valid_at(
      v_initialized_state,
      v_actor_address,
      v_callables_root,
      0,
      v_callable_count
    ) THEN
      RETURN "gw_ledger".result_error(v_initialized_context_root,'actor/invalid-callable');
    END IF;
    v_marked_state := "gw_ledger".mark_callables_at(
      v_initialized_state,
      v_actor_address,
      v_callables_root,
      0,
      v_callable_count,
      (o_initialized_context ->> 'block_height')::BIGINT
    );
    v_marked_context := "gw_ledger".context_with_state(v_initialized_context_root,v_marked_state);
    v_restored := "gw_ledger".context_restore(v_charged_context,v_marked_context,v_marked_state);
    RETURN "gw_ledger".result_ok(v_restored,v_actor_address);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.actor-runtime/execute-call [192] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_call(
  i_context_root BYTEA,
  i_op_root BYTEA,
  i_query BOOLEAN
) RETURNS JSONB AS $$

  DECLARE
    o_argument_context JSONB;
    o_arguments JSONB;
    o_called JSONB;
    o_called_context JSONB;
    o_entered_context JSONB;
    o_function JSONB;
    o_op JSONB;
    o_target JSONB;
    v_argument_context_root BYTEA;
    v_argument_count INTEGER;
    v_argument_roots JSONB;
    v_call_context BYTEA;
    v_called_context_root BYTEA;
    v_charged_context BYTEA;
    v_child_count INTEGER;
    v_entered_context BYTEA;
    v_frame_root BYTEA;
    v_function_root BYTEA;
    v_method_root BYTEA;
    v_parameter_count INTEGER;
    v_restored BYTEA;
    v_return_state BYTEA;
    v_target_root BYTEA;
  BEGIN
    o_op := "gw_ledger".op_get(i_op_root);
    v_child_count := "gw_ledger".cell_ref_count(i_op_root,'op-child');
    IF v_child_count < 1 THEN
      RETURN "gw_ledger".result_error(i_context_root,'actor/call-requires-target');
    END IF;
    o_target := "gw_ledger".execute(i_context_root,"gw_ledger".op_child_root(i_op_root,0));
    IF (o_target ->> 'status')::TEXT = 'error' THEN
      RETURN o_target;
    END IF;
    v_target_root := (o_target ->> 'value_root')::BYTEA;
    o_arguments := "gw_ledger".evaluate_children_at(
      (o_target ->> 'context_root')::BYTEA,
      i_op_root,
      1,
      v_child_count,
      jsonb_build_array()
    );
    IF (o_arguments ->> 'status')::TEXT = 'error' THEN
      RETURN o_arguments;
    END IF;
    v_argument_context_root := (o_arguments ->> 'context_root')::BYTEA;
    o_argument_context := "gw_ledger".context_get(v_argument_context_root);
    v_method_root := (o_op ->> 'value_root')::BYTEA;
    v_function_root := "gw_ledger".callable_function_root(
      (o_argument_context ->> 'state_root')::BYTEA,
      v_target_root,
      v_method_root
    );
    o_function := "gw_ledger".function_get(v_function_root);
    IF v_function_root IS NULL OR o_function IS NULL THEN
      RETURN "gw_ledger".result_error(v_argument_context_root,'actor/not-callable');
    END IF;
    v_argument_roots := (o_arguments ->> 'roots')::JSONB;
    v_argument_count := jsonb_array_length(v_argument_roots);
    v_parameter_count := "gw_ledger".cell_ref_count((o_function ->> 'parameters_root')::BYTEA,'element');
    IF NOT (v_argument_count = v_parameter_count) THEN
      RETURN "gw_ledger".result_error(v_argument_context_root,'actor/arity');
    END IF;
    IF NOT "gw_ledger".context_can_charge(v_argument_context_root,4) THEN
      RETURN "gw_ledger".result_error(v_argument_context_root,'cost-limit');
    END IF;
    v_charged_context := "gw_ledger".context_charge(v_argument_context_root,4);
    v_entered_context := "gw_ledger".context_enter(
      v_charged_context,
      (o_argument_context ->> 'state_root')::BYTEA,
      v_target_root,
      (o_argument_context ->> 'address')::BYTEA
    );
    o_entered_context := "gw_ledger".context_get(v_entered_context);
    v_frame_root := "gw_ledger".put_vector(
      v_argument_roots || "gw_ledger".vector_roots((o_function ->> 'closure_root')::BYTEA)
    );
    v_call_context := "gw_ledger".context_with_locals(
      v_entered_context,
      v_frame_root,
      (o_entered_context ->> 'depth')::INTEGER
    );
    o_called := "gw_ledger".execute(v_call_context,(o_function ->> 'body_root')::BYTEA);
    IF (o_called ->> 'status')::TEXT = 'error' THEN
      RETURN o_called;
    END IF;
    v_called_context_root := (o_called ->> 'context_root')::BYTEA;
    o_called_context := "gw_ledger".context_get(v_called_context_root);
    v_return_state := CASE WHEN i_query THEN (o_argument_context ->> 'state_root')::BYTEA
    ELSE (o_called_context ->> 'state_root')::BYTEA
    END;
    v_restored := "gw_ledger".context_restore(v_charged_context,v_called_context_root,v_return_state);
    RETURN "gw_ledger".result_ok(v_restored,(o_called ->> 'value_root')::BYTEA);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.actor-runtime/execute [287] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    v_special TEXT;
  BEGIN
    v_special := "gw_ledger".special_name(i_op_root);
    IF v_special = 'actor/deploy' THEN
      RETURN "gw_ledger".execute_deploy(i_context_root,i_op_root);
    ELSIF v_special = 'actor/call' THEN
      RETURN "gw_ledger".execute_call(i_context_root,i_op_root,false);
    ELSIF v_special = 'actor/query' THEN
      RETURN "gw_ledger".execute_call(i_context_root,i_op_root,true);
    ELSE
      RETURN "gw_ledger".result_error(i_context_root,'unknown-actor-operation');
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract-runtime/contract-special [33] 
CREATE OR REPLACE FUNCTION "gw_ledger".contract_special(
  i_op_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    v_special TEXT;
  BEGIN
    v_special := "gw_ledger".special_name(i_op_root);
    RETURN (v_special = 'contract/publish') OR (v_special = 'contract/open') OR (v_special = 'contract/apply') OR (v_special = 'contract/simulate') OR (v_special = 'contract/state') OR (v_special = 'contract/history') OR (v_special = 'contract/view');
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract-runtime/evaluated-roots [47] 
CREATE OR REPLACE FUNCTION "gw_ledger".evaluated_roots(
  i_context_root BYTEA,
  i_roots JSONB
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
      'roots',
      i_roots,
      'cost_used',
      (o_context ->> 'cost_used')::BIGINT
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract-runtime/evaluate-children-at [57] 
CREATE OR REPLACE FUNCTION "gw_ledger".evaluate_children_at(
  i_context_root BYTEA,
  i_op_root BYTEA,
  i_position INTEGER,
  i_count INTEGER,
  i_roots JSONB
) RETURNS JSONB AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN "gw_ledger".evaluated_roots(i_context_root,i_roots);
  ELSE
    DECLARE
    o_result JSONB;
      v_next_roots JSONB;
  BEGIN
    o_result := "gw_ledger".execute(
        i_context_root,
        "gw_ledger".op_child_root(i_op_root,i_position)
      );
      IF (o_result ->> 'status')::TEXT = 'error' THEN
        RETURN o_result;
      END IF;
      v_next_roots := (i_roots || jsonb_build_array(encode((o_result ->> 'value_root')::BYTEA,'hex')));
      RETURN "gw_ledger".evaluate_children_at(
        (o_result ->> 'context_root')::BYTEA,
        i_op_root,
        i_position + 1,
        i_count,
        v_next_roots
      );
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract-runtime/evaluate-children [82] 
CREATE OR REPLACE FUNCTION "gw_ledger".evaluate_children(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$
BEGIN
  RETURN "gw_ledger".evaluate_children_at(
    i_context_root,
    i_op_root,
    0,
    "gw_ledger".cell_ref_count(i_op_root,'op-child'),
    jsonb_build_array()
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract-runtime/root-at [92] 
CREATE OR REPLACE FUNCTION "gw_ledger".root_at(
  i_roots JSONB,
  i_position INTEGER
) RETURNS BYTEA AS $$
BEGIN
  RETURN decode((i_roots ->> i_position)::TEXT,'hex');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract-runtime/execute-one [99] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_one(
  i_context_root BYTEA,
  i_function_root BYTEA,
  i_argument_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    v_invoke_root BYTEA;
  BEGIN
    IF NOT "gw_ledger".function_arity(i_function_root,1) THEN
      RETURN "gw_ledger".result_error(i_context_root,'contract/function-arity');
    END IF;
    v_invoke_root := "gw_ledger".invoke(
      i_function_root,
      jsonb_build_array(encode("gw_ledger".constant(i_argument_root),'hex'))
    );
    RETURN "gw_ledger".execute(i_context_root,v_invoke_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract-runtime/execute-two [117] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_two(
  i_context_root BYTEA,
  i_function_root BYTEA,
  i_left_root BYTEA,
  i_right_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    v_invoke_root BYTEA;
  BEGIN
    IF NOT "gw_ledger".function_arity(i_function_root,2) THEN
      RETURN "gw_ledger".result_error(i_context_root,'contract/function-arity');
    END IF;
    v_invoke_root := "gw_ledger".invoke(i_function_root,jsonb_build_array(
      encode("gw_ledger".constant(i_left_root),'hex'),
      encode("gw_ledger".constant(i_right_root),'hex')
    ));
    RETURN "gw_ledger".execute(i_context_root,v_invoke_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract-runtime/pure-context [136] 
CREATE OR REPLACE FUNCTION "gw_ledger".pure_context(
  i_start_context_root BYTEA,
  i_result_context_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_start JSONB;
  BEGIN
    o_start := "gw_ledger".context_get(i_start_context_root);
    RETURN "gw_ledger".context_with_state(i_result_context_root,(o_start ->> 'state_root')::BYTEA);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract-runtime/event-payload-open [147] 
CREATE OR REPLACE FUNCTION "gw_ledger".event_payload_open(
  i_parameters_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_payload BYTEA;
  BEGIN
    v_payload := "gw_ledger".map_assoc(
      "gw_ledger".put_map(jsonb_build_array()),
      "gw_ledger".put_keyword('action'),
      "gw_ledger".put_keyword('contract/open')
    );
    RETURN "gw_ledger".map_assoc(
      v_payload,
      "gw_ledger".put_keyword('parameters'),
      i_parameters_root
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract-runtime/append-history [162] 
CREATE OR REPLACE FUNCTION "gw_ledger".append_history(
  i_history_root BYTEA,
  i_commit_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_vector(
    "gw_ledger".vector_roots(i_history_root) || jsonb_build_array(encode(i_commit_root,'hex'))
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract-runtime/execute-publish [172] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_publish(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_arguments JSONB;
    o_context JSONB;
    v_account_root BYTEA;
    v_alias_root BYTEA;
    v_context_root BYTEA;
    v_count INTEGER;
    v_next_account BYTEA;
    v_next_context BYTEA;
    v_next_state BYTEA;
    v_publication_root BYTEA;
    v_roots JSONB;
    v_template_root BYTEA;
  BEGIN
    v_count := "gw_ledger".cell_ref_count(i_op_root,'op-child');
    IF NOT (v_count = 2) THEN
      RETURN "gw_ledger".result_error(i_context_root,'contract/publish-arity');
    END IF;
    o_arguments := "gw_ledger".evaluate_children(i_context_root,i_op_root);
    IF (o_arguments ->> 'status')::TEXT = 'error' THEN
      RETURN o_arguments;
    END IF;
    v_roots := (o_arguments ->> 'roots')::JSONB;
    v_context_root := (o_arguments ->> 'context_root')::BYTEA;
    o_context := "gw_ledger".context_get(v_context_root);
    v_template_root := "gw_ledger".root_at(v_roots,0);
    v_alias_root := "gw_ledger".root_at(v_roots,1);
    IF NOT "gw_ledger".template_valid(v_template_root) THEN
      RETURN "gw_ledger".result_error(v_context_root,'contract/invalid-template');
    END IF;
    IF NOT ("gw_ledger".field(v_template_root,'contract/publisher') = (o_context ->> 'origin')::BYTEA) THEN
      RETURN "gw_ledger".result_error(v_context_root,'contract/publisher-mismatch');
    END IF;
    IF NOT ("gw_ledger".cell_type_tag(v_alias_root) = 7) THEN
      RETURN "gw_ledger".result_error(v_context_root,'contract/alias-not-symbol');
    END IF;
    IF NOT "gw_ledger".context_can_charge(v_context_root,4) THEN
      RETURN "gw_ledger".result_error(v_context_root,'cost-limit');
    END IF;
    v_account_root := "gw_ledger".state_account_root(
      (o_context ->> 'state_root')::BYTEA,
      (o_context ->> 'address')::BYTEA
    );
    IF v_account_root is null  THEN
      RETURN "gw_ledger".result_error(v_context_root,'missing-account');
    END IF;
    v_next_account := "gw_ledger".account_value_define(v_account_root,v_alias_root,v_template_root);
    v_next_state := "gw_ledger".state_assoc_account(
      (o_context ->> 'state_root')::BYTEA,
      (o_context ->> 'address')::BYTEA,
      v_next_account,
      (o_context ->> 'block_height')::BIGINT
    );
    v_next_context := "gw_ledger".context_charge(
      "gw_ledger".context_with_state(v_context_root,v_next_state),
      4
    );
    v_publication_root := "gw_ledger".publication_put(
      v_template_root,
      (o_context ->> 'origin')::BYTEA,
      v_alias_root,
      (o_context ->> 'transaction_root')::BYTEA,
      (o_context ->> 'timestamp')::BIGINT
    );
    RETURN "gw_ledger".result_ok(v_next_context,v_publication_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract-runtime/execute-open [243] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_open(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_arguments JSONB;
    o_initialized JSONB;
    o_pure_context JSONB;
    v_address_root BYTEA;
    v_argument_context_root BYTEA;
    v_charged_context BYTEA;
    v_commit_root BYTEA;
    v_count INTEGER;
    v_event_root BYTEA;
    v_existing BYTEA;
    v_history_root BYTEA;
    v_initial_state BYTEA;
    v_instance_account BYTEA;
    v_next_context BYTEA;
    v_next_state BYTEA;
    v_nil_root BYTEA;
    v_open_payload BYTEA;
    v_parameters_root BYTEA;
    v_pure_context BYTEA;
    v_roots JSONB;
    v_template_root BYTEA;
  BEGIN
    v_count := "gw_ledger".cell_ref_count(i_op_root,'op-child');
    IF NOT (v_count = 2) THEN
      RETURN "gw_ledger".result_error(i_context_root,'contract/open-arity');
    END IF;
    o_arguments := "gw_ledger".evaluate_children(i_context_root,i_op_root);
    IF (o_arguments ->> 'status')::TEXT = 'error' THEN
      RETURN o_arguments;
    END IF;
    v_roots := (o_arguments ->> 'roots')::JSONB;
    v_argument_context_root := (o_arguments ->> 'context_root')::BYTEA;
    v_template_root := "gw_ledger".root_at(v_roots,0);
    v_parameters_root := "gw_ledger".root_at(v_roots,1);
    IF NOT "gw_ledger".template_valid(v_template_root) THEN
      RETURN "gw_ledger".result_error(v_argument_context_root,'contract/invalid-template');
    END IF;
    IF NOT "gw_ledger".context_can_charge(v_argument_context_root,8) THEN
      RETURN "gw_ledger".result_error(v_argument_context_root,'cost-limit');
    END IF;
    v_charged_context := "gw_ledger".context_charge(v_argument_context_root,8);
    o_initialized := "gw_ledger".execute_one(
      v_charged_context,
      "gw_ledger".field(v_template_root,'contract/init'),
      v_parameters_root
    );
    IF (o_initialized ->> 'status')::TEXT = 'error' THEN
      RETURN o_initialized;
    END IF;
    v_pure_context := "gw_ledger".pure_context(v_charged_context,(o_initialized ->> 'context_root')::BYTEA);
    o_pure_context := "gw_ledger".context_get(v_pure_context);
    v_initial_state := (o_initialized ->> 'value_root')::BYTEA;
    v_address_root := "gw_ledger".address_root(v_pure_context,i_op_root);
    v_existing := "gw_ledger".state_account_root((o_pure_context ->> 'state_root')::BYTEA,v_address_root);
    IF v_existing is not null  THEN
      RETURN "gw_ledger".result_error(v_pure_context,'contract/address-exists');
    END IF;
    v_nil_root := "gw_ledger".put_nil();
    v_open_payload := "gw_ledger".event_payload_open(v_parameters_root);
    v_event_root := "gw_ledger".verified_event_put(
      v_open_payload,
      v_address_root,
      v_template_root,
      (o_pure_context ->> 'origin')::BYTEA,
      (o_pure_context ->> 'transaction_root')::BYTEA,
      (o_pure_context ->> 'timestamp')::BIGINT,
      v_nil_root
    );
    v_commit_root := "gw_ledger".commit_put(
      v_address_root,
      v_template_root,
      v_nil_root,
      v_event_root,
      (o_pure_context ->> 'origin')::BYTEA,
      v_nil_root,
      v_initial_state,
      (o_pure_context ->> 'transaction_root')::BYTEA,
      (o_pure_context ->> 'timestamp')::BIGINT
    );
    v_history_root := "gw_ledger".put_vector(jsonb_build_array(encode(v_commit_root,'hex')));
    v_instance_account := "gw_ledger".instance_account_create(
      (o_pure_context ->> 'address')::BYTEA,
      v_template_root,
      v_initial_state,
      v_commit_root,
      v_history_root
    );
    v_next_state := "gw_ledger".state_assoc_account(
      (o_pure_context ->> 'state_root')::BYTEA,
      v_address_root,
      v_instance_account,
      (o_pure_context ->> 'block_height')::BIGINT
    );
    v_next_context := "gw_ledger".context_with_state(v_pure_context,v_next_state);
    RETURN "gw_ledger".result_ok(v_next_context,v_address_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract-runtime/execute-apply [344] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_apply(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_arguments JSONB;
    o_charged JSONB;
    o_context JSONB;
    o_pure JSONB;
    o_reduced JSONB;
    v_address_root BYTEA;
    v_argument_context_root BYTEA;
    v_charged_context BYTEA;
    v_count INTEGER;
    v_current_head BYTEA;
    v_current_state BYTEA;
    v_error_root BYTEA;
    v_event_root BYTEA;
    v_expected_head_root BYTEA;
    v_global_state BYTEA;
    v_history_root BYTEA;
    v_next_contract_state BYTEA;
    v_payload_root BYTEA;
    v_pure_context BYTEA;
    v_reducer_result BYTEA;
    v_roots JSONB;
    v_template_root BYTEA;
  BEGIN
    v_count := "gw_ledger".cell_ref_count(i_op_root,'op-child');
    IF NOT (v_count = 3) THEN
      RETURN "gw_ledger".result_error(i_context_root,'contract/apply-arity');
    END IF;
    o_arguments := "gw_ledger".evaluate_children(i_context_root,i_op_root);
    IF (o_arguments ->> 'status')::TEXT = 'error' THEN
      RETURN o_arguments;
    END IF;
    v_roots := (o_arguments ->> 'roots')::JSONB;
    v_argument_context_root := (o_arguments ->> 'context_root')::BYTEA;
    o_context := "gw_ledger".context_get(v_argument_context_root);
    v_address_root := "gw_ledger".root_at(v_roots,0);
    v_expected_head_root := "gw_ledger".root_at(v_roots,1);
    v_payload_root := "gw_ledger".root_at(v_roots,2);
    v_global_state := (o_context ->> 'state_root')::BYTEA;
    IF NOT "gw_ledger".instance_valid(v_global_state,v_address_root) THEN
      RETURN "gw_ledger".result_error(v_argument_context_root,'contract/missing-instance');
    END IF;
    v_template_root := "gw_ledger".instance_template(v_global_state,v_address_root);
    v_current_state := "gw_ledger".instance_state(v_global_state,v_address_root);
    v_current_head := "gw_ledger".instance_head(v_global_state,v_address_root);
    v_history_root := "gw_ledger".instance_history(v_global_state,v_address_root);
    IF NOT (v_current_head = v_expected_head_root) THEN
      RETURN "gw_ledger".result_error(v_argument_context_root,'contract/head-changed');
    END IF;
    IF NOT ("gw_ledger".cell_type_tag(v_payload_root) = 11) THEN
      RETURN "gw_ledger".result_error(v_argument_context_root,'contract/event-not-map');
    END IF;
    IF NOT "gw_ledger".context_can_charge(v_argument_context_root,8) THEN
      RETURN "gw_ledger".result_error(v_argument_context_root,'cost-limit');
    END IF;
    v_charged_context := "gw_ledger".context_charge(v_argument_context_root,8);
    o_charged := "gw_ledger".context_get(v_charged_context);
    v_event_root := "gw_ledger".verified_event_put(
      v_payload_root,
      v_address_root,
      v_template_root,
      (o_charged ->> 'origin')::BYTEA,
      (o_charged ->> 'transaction_root')::BYTEA,
      (o_charged ->> 'timestamp')::BIGINT,
      v_current_head
    );
    o_reduced := "gw_ledger".execute_two(
      v_charged_context,
      "gw_ledger".field(v_template_root,'contract/transition'),
      v_current_state,
      v_event_root
    );
    IF (o_reduced ->> 'status')::TEXT = 'error' THEN
      RETURN o_reduced;
    END IF;
    v_pure_context := "gw_ledger".pure_context(v_charged_context,(o_reduced ->> 'context_root')::BYTEA);
    o_pure := "gw_ledger".context_get(v_pure_context);
    v_reducer_result := (o_reduced ->> 'value_root')::BYTEA;
    IF NOT ("gw_ledger".cell_type_tag(v_reducer_result) = 11) THEN
      RETURN "gw_ledger".result_error(v_pure_context,'contract/invalid-transition-result');
    END IF;
    v_error_root := "gw_ledger".map_get(v_reducer_result,"gw_ledger".put_keyword('error'));
    v_next_contract_state := "gw_ledger".map_get(v_reducer_result,"gw_ledger".put_keyword('ok'));
    IF v_error_root is not null  THEN
      RETURN "gw_ledger".result_ok(v_pure_context,v_reducer_result);
    ELSIF v_next_contract_state is null  THEN
      RETURN "gw_ledger".result_error(v_pure_context,'contract/transition-missing-ok');
    ELSE
      DECLARE
      v_account_root BYTEA;
        v_commit_root BYTEA;
        v_next_account BYTEA;
        v_next_context BYTEA;
        v_next_global_state BYTEA;
        v_next_history BYTEA;
        v_result_root BYTEA;
    BEGIN
      v_commit_root := "gw_ledger".commit_put(
          v_address_root,
          v_template_root,
          v_current_head,
          v_event_root,
          (o_pure ->> 'origin')::BYTEA,
          v_current_state,
          v_next_contract_state,
          (o_pure ->> 'transaction_root')::BYTEA,
          (o_pure ->> 'timestamp')::BIGINT
        );
        v_next_history := "gw_ledger".append_history(v_history_root,v_commit_root);
        v_account_root := "gw_ledger".state_account_root((o_pure ->> 'state_root')::BYTEA,v_address_root);
        v_next_account := "gw_ledger".instance_account_update(
          v_account_root,
          v_next_contract_state,
          v_commit_root,
          v_next_history
        );
        v_next_global_state := "gw_ledger".state_assoc_account(
          (o_pure ->> 'state_root')::BYTEA,
          v_address_root,
          v_next_account,
          (o_pure ->> 'block_height')::BIGINT
        );
        v_next_context := "gw_ledger".context_with_state(v_pure_context,v_next_global_state);
        v_result_root := "gw_ledger".result_put(
          v_address_root,
          v_commit_root,
          v_next_contract_state,
          v_reducer_result,
          true
        );
        RETURN "gw_ledger".result_ok(v_next_context,v_result_root);
    END;
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract-runtime/execute-simulate [491] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_simulate(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_arguments JSONB;
    o_charged JSONB;
    o_context JSONB;
    o_reduced JSONB;
    v_address_root BYTEA;
    v_argument_context_root BYTEA;
    v_charged_context BYTEA;
    v_count INTEGER;
    v_current_head BYTEA;
    v_current_state BYTEA;
    v_error_root BYTEA;
    v_event_root BYTEA;
    v_global_state BYTEA;
    v_hypothetical_state BYTEA;
    v_next_state BYTEA;
    v_payload_root BYTEA;
    v_pure_context BYTEA;
    v_reducer_result BYTEA;
    v_result_root BYTEA;
    v_roots JSONB;
    v_template_root BYTEA;
  BEGIN
    v_count := "gw_ledger".cell_ref_count(i_op_root,'op-child');
    IF NOT (v_count = 2) THEN
      RETURN "gw_ledger".result_error(i_context_root,'contract/simulate-arity');
    END IF;
    o_arguments := "gw_ledger".evaluate_children(i_context_root,i_op_root);
    IF (o_arguments ->> 'status')::TEXT = 'error' THEN
      RETURN o_arguments;
    END IF;
    v_roots := (o_arguments ->> 'roots')::JSONB;
    v_argument_context_root := (o_arguments ->> 'context_root')::BYTEA;
    o_context := "gw_ledger".context_get(v_argument_context_root);
    v_address_root := "gw_ledger".root_at(v_roots,0);
    v_payload_root := "gw_ledger".root_at(v_roots,1);
    v_global_state := (o_context ->> 'state_root')::BYTEA;
    IF NOT "gw_ledger".instance_valid(v_global_state,v_address_root) THEN
      RETURN "gw_ledger".result_error(v_argument_context_root,'contract/missing-instance');
    END IF;
    v_template_root := "gw_ledger".instance_template(v_global_state,v_address_root);
    v_current_state := "gw_ledger".instance_state(v_global_state,v_address_root);
    v_current_head := "gw_ledger".instance_head(v_global_state,v_address_root);
    IF NOT ("gw_ledger".cell_type_tag(v_payload_root) = 11) THEN
      RETURN "gw_ledger".result_error(v_argument_context_root,'contract/event-not-map');
    END IF;
    IF NOT "gw_ledger".context_can_charge(v_argument_context_root,4) THEN
      RETURN "gw_ledger".result_error(v_argument_context_root,'cost-limit');
    END IF;
    v_charged_context := "gw_ledger".context_charge(v_argument_context_root,4);
    o_charged := "gw_ledger".context_get(v_charged_context);
    v_event_root := "gw_ledger".verified_event_put(
      v_payload_root,
      v_address_root,
      v_template_root,
      (o_charged ->> 'origin')::BYTEA,
      (o_charged ->> 'transaction_root')::BYTEA,
      (o_charged ->> 'timestamp')::BIGINT,
      v_current_head
    );
    o_reduced := "gw_ledger".execute_two(
      v_charged_context,
      "gw_ledger".field(v_template_root,'contract/transition'),
      v_current_state,
      v_event_root
    );
    IF (o_reduced ->> 'status')::TEXT = 'error' THEN
      RETURN o_reduced;
    END IF;
    v_pure_context := "gw_ledger".pure_context(v_charged_context,(o_reduced ->> 'context_root')::BYTEA);
    v_reducer_result := (o_reduced ->> 'value_root')::BYTEA;
    IF NOT ("gw_ledger".cell_type_tag(v_reducer_result) = 11) THEN
      RETURN "gw_ledger".result_error(v_pure_context,'contract/invalid-transition-result');
    END IF;
    v_error_root := "gw_ledger".map_get(v_reducer_result,"gw_ledger".put_keyword('error'));
    v_next_state := "gw_ledger".map_get(v_reducer_result,"gw_ledger".put_keyword('ok'));
    v_hypothetical_state := CASE WHEN v_error_root IS NOT NULL THEN v_current_state
    WHEN v_next_state IS NULL THEN v_current_state
    ELSE v_next_state
    END;
    v_result_root := "gw_ledger".result_put(
      v_address_root,
      v_current_head,
      v_hypothetical_state,
      v_reducer_result,
      false
    );
    RETURN "gw_ledger".result_ok(v_pure_context,v_result_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract-runtime/execute-read [591] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_read(
  i_context_root BYTEA,
  i_op_root BYTEA,
  i_history BOOLEAN
) RETURNS JSONB AS $$

  DECLARE
    o_context JSONB;
    o_target JSONB;
    v_address_root BYTEA;
    v_context_root BYTEA;
    v_count INTEGER;
    v_global_state BYTEA;
    v_value_root BYTEA;
  BEGIN
    v_count := "gw_ledger".cell_ref_count(i_op_root,'op-child');
    IF NOT (v_count = 1) THEN
      RETURN "gw_ledger".result_error(i_context_root,'contract/read-arity');
    END IF;
    o_target := "gw_ledger".execute(i_context_root,"gw_ledger".op_child_root(i_op_root,0));
    IF (o_target ->> 'status')::TEXT = 'error' THEN
      RETURN o_target;
    END IF;
    v_context_root := (o_target ->> 'context_root')::BYTEA;
    o_context := "gw_ledger".context_get(v_context_root);
    v_address_root := (o_target ->> 'value_root')::BYTEA;
    v_global_state := (o_context ->> 'state_root')::BYTEA;
    IF NOT "gw_ledger".instance_valid(v_global_state,v_address_root) THEN
      RETURN "gw_ledger".result_error(v_context_root,'contract/missing-instance');
    END IF;
    IF NOT "gw_ledger".context_can_charge(v_context_root,1) THEN
      RETURN "gw_ledger".result_error(v_context_root,'cost-limit');
    END IF;
    v_value_root := CASE WHEN i_history THEN "gw_ledger".instance_history(v_global_state,v_address_root)
    ELSE "gw_ledger".instance_state(v_global_state,v_address_root)
    END;
    RETURN "gw_ledger".result_ok("gw_ledger".context_charge(v_context_root,1),v_value_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract-runtime/execute-view [636] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_view(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_context JSONB;
    o_op JSONB;
    o_target JSONB;
    o_view JSONB;
    v_address_root BYTEA;
    v_charged_context BYTEA;
    v_context_root BYTEA;
    v_contract_state BYTEA;
    v_count INTEGER;
    v_global_state BYTEA;
    v_pure_context BYTEA;
    v_template_root BYTEA;
    v_view_root BYTEA;
    v_views_root BYTEA;
  BEGIN
    v_count := "gw_ledger".cell_ref_count(i_op_root,'op-child');
    IF NOT (v_count = 1) THEN
      RETURN "gw_ledger".result_error(i_context_root,'contract/view-arity');
    END IF;
    o_target := "gw_ledger".execute(i_context_root,"gw_ledger".op_child_root(i_op_root,0));
    IF (o_target ->> 'status')::TEXT = 'error' THEN
      RETURN o_target;
    END IF;
    v_context_root := (o_target ->> 'context_root')::BYTEA;
    o_context := "gw_ledger".context_get(v_context_root);
    o_op := "gw_ledger".op_get(i_op_root);
    v_address_root := (o_target ->> 'value_root')::BYTEA;
    v_global_state := (o_context ->> 'state_root')::BYTEA;
    IF NOT "gw_ledger".instance_valid(v_global_state,v_address_root) THEN
      RETURN "gw_ledger".result_error(v_context_root,'contract/missing-instance');
    END IF;
    v_template_root := "gw_ledger".instance_template(v_global_state,v_address_root);
    v_contract_state := "gw_ledger".instance_state(v_global_state,v_address_root);
    v_views_root := "gw_ledger".field(v_template_root,'contract/views');
    v_view_root := "gw_ledger".map_get(v_views_root,(o_op ->> 'value_root')::BYTEA);
    IF NOT "gw_ledger".function_arity(v_view_root,1) THEN
      RETURN "gw_ledger".result_error(v_context_root,'contract/missing-view');
    END IF;
    IF NOT "gw_ledger".context_can_charge(v_context_root,3) THEN
      RETURN "gw_ledger".result_error(v_context_root,'cost-limit');
    END IF;
    v_charged_context := "gw_ledger".context_charge(v_context_root,3);
    o_view := "gw_ledger".execute_one(v_charged_context,v_view_root,v_contract_state);
    IF (o_view ->> 'status')::TEXT = 'error' THEN
      RETURN o_view;
    END IF;
    v_pure_context := "gw_ledger".pure_context(v_charged_context,(o_view ->> 'context_root')::BYTEA);
    RETURN "gw_ledger".result_ok(v_pure_context,(o_view ->> 'value_root')::BYTEA);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.contract-runtime/execute [702] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    v_special TEXT;
  BEGIN
    v_special := "gw_ledger".special_name(i_op_root);
    IF v_special = 'contract/publish' THEN
      RETURN "gw_ledger".execute_publish(i_context_root,i_op_root);
    ELSIF v_special = 'contract/open' THEN
      RETURN "gw_ledger".execute_open(i_context_root,i_op_root);
    ELSIF v_special = 'contract/apply' THEN
      RETURN "gw_ledger".execute_apply(i_context_root,i_op_root);
    ELSIF v_special = 'contract/simulate' THEN
      RETURN "gw_ledger".execute_simulate(i_context_root,i_op_root);
    ELSIF v_special = 'contract/state' THEN
      RETURN "gw_ledger".execute_read(i_context_root,i_op_root,false);
    ELSIF v_special = 'contract/history' THEN
      RETURN "gw_ledger".execute_read(i_context_root,i_op_root,true);
    ELSIF v_special = 'contract/view' THEN
      RETURN "gw_ledger".execute_view(i_context_root,i_op_root);
    ELSE
      RETURN "gw_ledger".result_error(i_context_root,'unknown-contract-operation');
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol-runtime/arguments-ok [33] 
CREATE OR REPLACE FUNCTION "gw_ledger".arguments_ok(
  i_context_root BYTEA,
  i_roots JSONB
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
      'roots',
      i_roots,
      'cost_used',
      (o_context ->> 'cost_used')::BIGINT
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol-runtime/evaluate-arguments-at [43] 
CREATE OR REPLACE FUNCTION "gw_ledger".evaluate_arguments_at(
  i_context_root BYTEA,
  i_op_root BYTEA,
  i_position INTEGER,
  i_count INTEGER,
  i_roots JSONB
) RETURNS JSONB AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN "gw_ledger".arguments_ok(i_context_root,i_roots);
  ELSE
    DECLARE
    o_result JSONB;
      v_child_root BYTEA;
  BEGIN
    v_child_root := "gw_ledger".op_child_root(i_op_root,i_position);
      o_result := "gw_ledger".execute(i_context_root,v_child_root);
      IF (o_result ->> 'status')::TEXT = 'error' THEN
        RETURN o_result;
      ELSE
        DECLARE
        v_next_roots JSONB;
      BEGIN
        v_next_roots := (i_roots || jsonb_build_array(encode((o_result ->> 'value_root')::BYTEA,'hex')));
          RETURN "gw_ledger".evaluate_arguments_at(
            (o_result ->> 'context_root')::BYTEA,
            i_op_root,
            i_position + 1,
            i_count,
            v_next_roots
          );
      END;
      END IF;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol-runtime/evaluate-arguments [68] 
CREATE OR REPLACE FUNCTION "gw_ledger".evaluate_arguments(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$
BEGIN
  RETURN "gw_ledger".evaluate_arguments_at(
    i_context_root,
    i_op_root,
    0,
    "gw_ledger".cell_ref_count(i_op_root,'op-child'),
    jsonb_build_array()
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol-runtime/argument-root [78] 
CREATE OR REPLACE FUNCTION "gw_ledger".argument_root(
  i_roots JSONB,
  i_position INTEGER
) RETURNS BYTEA AS $$
BEGIN
  RETURN decode((i_roots ->> i_position)::TEXT,'hex');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol-runtime/copy-argument-tail-at [84] 
CREATE OR REPLACE FUNCTION "gw_ledger".copy_argument_tail_at(
  i_roots JSONB,
  i_position INTEGER,
  i_count INTEGER,
  i_out JSONB
) RETURNS JSONB AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN i_out;
  ELSE
    RETURN "gw_ledger".copy_argument_tail_at(
      i_roots,
      i_position + 1,
      i_count,
      i_out || jsonb_build_array((i_roots ->> i_position)::TEXT)
    );
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol-runtime/execute-protocol-define [98] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_protocol_define(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_arguments JSONB;
    v_count INTEGER;
    v_roots JSONB;
  BEGIN
    v_count := "gw_ledger".cell_ref_count(i_op_root,'op-child');
    IF NOT (v_count = 2) THEN
      RETURN "gw_ledger".result_error(i_context_root,'protocol/define-arity');
    END IF;
    o_arguments := "gw_ledger".evaluate_arguments(i_context_root,i_op_root);
    IF (o_arguments ->> 'status')::TEXT = 'error' THEN
      RETURN o_arguments;
    END IF;
    v_roots := (o_arguments ->> 'roots')::JSONB;
    RETURN "gw_ledger".define_transition(
      (o_arguments ->> 'context_root')::BYTEA,
      "gw_ledger".argument_root(v_roots,0),
      "gw_ledger".argument_root(v_roots,1)
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol-runtime/execute-protocol-extend [117] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_protocol_extend(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_arguments JSONB;
    v_count INTEGER;
    v_roots JSONB;
  BEGIN
    v_count := "gw_ledger".cell_ref_count(i_op_root,'op-child');
    IF NOT (v_count = 3) THEN
      RETURN "gw_ledger".result_error(i_context_root,'protocol/extend-arity');
    END IF;
    o_arguments := "gw_ledger".evaluate_arguments(i_context_root,i_op_root);
    IF (o_arguments ->> 'status')::TEXT = 'error' THEN
      RETURN o_arguments;
    END IF;
    v_roots := (o_arguments ->> 'roots')::JSONB;
    RETURN "gw_ledger".extend_transition(
      (o_arguments ->> 'context_root')::BYTEA,
      "gw_ledger".argument_root(v_roots,0),
      "gw_ledger".argument_root(v_roots,1),
      "gw_ledger".argument_root(v_roots,2)
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol-runtime/execute-protocol-invoke [137] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_protocol_invoke(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_arguments JSONB;
    o_context JSONB;
    o_function JSONB;
    v_argument_context_root BYTEA;
    v_call_arity INTEGER;
    v_call_context BYTEA;
    v_count INTEGER;
    v_declared_arity BIGINT;
    v_function_context BYTEA;
    v_function_root BYTEA;
    v_local_roots JSONB;
    v_locals_root BYTEA;
    v_method_name_root BYTEA;
    v_parameter_count INTEGER;
    v_protocol_root BYTEA;
    v_receiver_root BYTEA;
    v_roots JSONB;
  BEGIN
    v_count := "gw_ledger".cell_ref_count(i_op_root,'op-child');
    IF v_count < 3 THEN
      RETURN "gw_ledger".result_error(i_context_root,'protocol/invoke-arity');
    END IF;
    o_arguments := "gw_ledger".evaluate_arguments(i_context_root,i_op_root);
    IF (o_arguments ->> 'status')::TEXT = 'error' THEN
      RETURN o_arguments;
    END IF;
    v_roots := (o_arguments ->> 'roots')::JSONB;
    v_argument_context_root := (o_arguments ->> 'context_root')::BYTEA;
    o_context := "gw_ledger".context_get(v_argument_context_root);
    v_protocol_root := "gw_ledger".argument_root(v_roots,0);
    v_method_name_root := "gw_ledger".argument_root(v_roots,1);
    v_receiver_root := "gw_ledger".argument_root(v_roots,2);
    v_declared_arity := "gw_ledger".method_arity(v_protocol_root,v_method_name_root);
    v_call_arity := (v_count - 2);
    IF NOT (v_declared_arity = v_call_arity) THEN
      RETURN "gw_ledger".result_error(v_argument_context_root,'protocol/method-arity');
    END IF;
    v_function_root := "gw_ledger".resolve_method(
      (o_context ->> 'state_root')::BYTEA,
      (o_context ->> 'address')::BYTEA,
      v_protocol_root,
      v_method_name_root,
      v_receiver_root
    );
    o_function := "gw_ledger".function_get(v_function_root);
    IF v_function_root IS NULL OR o_function IS NULL OR NOT "gw_ledger".function_valid(v_function_root) THEN
      RETURN "gw_ledger".result_error(v_argument_context_root,'missing-protocol-implementation');
    END IF;
    v_parameter_count := "gw_ledger".cell_ref_count((o_function ->> 'parameters_root')::BYTEA,'element');
    IF NOT (v_parameter_count = v_call_arity) THEN
      RETURN "gw_ledger".result_error(v_argument_context_root,'protocol/function-arity');
    END IF;
    IF NOT "gw_ledger".context_can_charge(v_argument_context_root,3) THEN
      RETURN "gw_ledger".result_error(v_argument_context_root,'cost-limit');
    END IF;
    v_local_roots := "gw_ledger".copy_argument_tail_at(v_roots,2,v_count,jsonb_build_array());
    v_locals_root := "gw_ledger".put_vector(v_local_roots);
    v_function_context := "gw_ledger".context_with_locals(
      v_argument_context_root,
      v_locals_root,
      (o_context ->> 'depth')::INTEGER + 1
    );
    v_call_context := "gw_ledger".context_charge(v_function_context,3);
    RETURN "gw_ledger".execute(v_call_context,(o_function ->> 'body_root')::BYTEA);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol-runtime/execute-account-primitive [204] 
CREATE OR REPLACE FUNCTION "gw_ledger".execute_account_primitive(
  i_context_root BYTEA,
  i_op_root BYTEA,
  i_primitive_id TEXT
) RETURNS JSONB AS $$

  DECLARE
    o_arguments JSONB;
  BEGIN
    o_arguments := "gw_ledger".evaluate_arguments(i_context_root,i_op_root);
    IF (o_arguments ->> 'status')::TEXT = 'error' THEN
      RETURN o_arguments;
    END IF;
    RETURN "gw_ledger".apply_primitive(
      (o_arguments ->> 'context_root')::BYTEA,
      i_primitive_id,
      (o_arguments ->> 'roots')::JSONB
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.protocol-runtime/protocol-execute [218] 
CREATE OR REPLACE FUNCTION "gw_ledger".protocol_execute(
  i_context_root BYTEA,
  i_op_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_op JSONB;
    o_primitive JSONB;
    v_kind TEXT;
    v_primitive_id TEXT;
  BEGIN
    o_op := "gw_ledger".op_get(i_op_root);
    v_kind := CASE WHEN o_op IS NULL THEN ''
    ELSE (o_op ->> 'op_kind')::TEXT
    END;
    o_primitive := CASE WHEN v_kind = 'invoke' THEN "gw_ledger".primitive_get_root((o_op ->> 'function_root')::BYTEA)
    ELSE null
    END;
    v_primitive_id := CASE WHEN o_primitive IS NULL THEN ''
    ELSE (o_primitive ->> 'primitive_id')::TEXT
    END;
    IF "gw_ledger".contract_special(i_op_root) THEN
      RETURN "gw_ledger".execute(i_context_root,i_op_root);
    ELSIF "gw_ledger".actor_special(i_op_root) THEN
      RETURN "gw_ledger".execute(i_context_root,i_op_root);
    ELSIF "gw_ledger".account_primitive_id(v_primitive_id) THEN
      RETURN "gw_ledger".execute_account_primitive(i_context_root,i_op_root,v_primitive_id);
    ELSIF v_primitive_id = 'protocol/define' THEN
      RETURN "gw_ledger".execute_protocol_define(i_context_root,i_op_root);
    ELSIF v_primitive_id = 'protocol/extend' THEN
      RETURN "gw_ledger".execute_protocol_extend(i_context_root,i_op_root);
    ELSIF v_primitive_id = 'protocol/invoke' THEN
      RETURN "gw_ledger".execute_protocol_invoke(i_context_root,i_op_root);
    ELSE
      RETURN "gw_ledger".execute(i_context_root,i_op_root);
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- gwdb.ledger.transaction/Transaction [32] 
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

-- gwdb.ledger.transaction/TransactionReceipt [49] 
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

-- gwdb.ledger.transaction/transaction-root-hex [61] 
CREATE OR REPLACE FUNCTION "gw_ledger".transaction_root_hex(
  i_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN CASE WHEN i_root IS NULL THEN '-'
  ELSE encode(i_root,'hex')
  END;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.transaction/transaction-signing-payload [69] 
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

-- gwdb.ledger.transaction/transaction-payload [84] 
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

-- gwdb.ledger.transaction/transaction-put [101] 
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
    o_runtime_ref JSONB;
    o_upsert JSONB;
    v_payload BYTEA;
    v_root BYTEA;
  BEGIN
    o_origin := "gw_ledger".cell_by_hash(i_origin);
    o_op := "gw_ledger".cell_by_hash(i_op_root);
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
    IF NOT ("gw_ledger".runtime_root_valid(i_runtime_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_runtime_root','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-runtime-root'
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

-- gwdb.ledger.transaction/transaction-get [158] 
CREATE OR REPLACE FUNCTION "gw_ledger".transaction_get(
  i_transaction_root BYTEA
) RETURNS JSONB AS $$
BEGIN
  RETURN WITH j_ret AS (  
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
  SELECT to_jsonb(j_ret) FROM j_ret;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.transaction/transaction-root-valid [165] 
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

-- gwdb.ledger.transaction/transaction-signature-valid [192] 
CREATE OR REPLACE FUNCTION "gw_ledger".transaction_signature_valid(
  i_transaction_root BYTEA,
  i_state_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_key JSONB;
    o_tx JSONB;
    v_account_root BYTEA;
    v_key_root BYTEA;
    v_message BYTEA;
  BEGIN
    o_tx := "gw_ledger".transaction_get(i_transaction_root);
    v_account_root := CASE WHEN o_tx IS NULL THEN null
    ELSE "gw_ledger".state_account_root(i_state_root,(o_tx ->> 'origin')::BYTEA)
    END;
    v_key_root := CASE WHEN v_account_root IS NULL THEN null
    ELSE "gw_ledger".account_value_key_root(v_account_root)
    END;
    o_key := "gw_ledger".cell_by_hash(v_key_root);
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
    RETURN o_tx IS NOT NULL AND v_account_root IS NOT NULL AND "gw_ledger".public_key_root_valid(v_key_root) AND "gw_ledger".signature_verify(
      (o_tx ->> 'signature')::BYTEA,
      v_message,
      (o_key ->> 'payload')::BYTEA
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.transaction/transaction-valid [228] 
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
    RETURN o_tx IS NOT NULL AND "gw_ledger".transaction_root_valid(i_transaction_root) AND "gw_ledger".state_root_valid(i_state_root) AND ((o_tx ->> 'network')::TEXT = i_network) AND "gw_ledger".op_valid((o_tx ->> 'op_root')::BYTEA) AND "gw_ledger".runtime_root_valid((o_tx ->> 'runtime_root')::BYTEA) AND v_account_root IS NOT NULL AND ((o_tx ->> 'sequence')::BIGINT = "gw_ledger".integer_bigint("gw_ledger".account_value_sequence_root(v_account_root))) AND ((o_tx ->> 'cost_limit')::BIGINT >= 1);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.transaction/transaction-signed-valid [253] 
CREATE OR REPLACE FUNCTION "gw_ledger".transaction_signed_valid(
  i_transaction_root BYTEA,
  i_network TEXT,
  i_state_root BYTEA
) RETURNS BOOLEAN AS $$
BEGIN
  RETURN "gw_ledger".transaction_valid(i_transaction_root,i_network,i_state_root) AND "gw_ledger".transaction_signature_valid(i_transaction_root,i_state_root);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.transaction/receipt-payload [264] 
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

-- gwdb.ledger.transaction/transaction-receipt-put [281] 
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

-- gwdb.ledger.transaction/transaction-receipt-get [307] 
CREATE OR REPLACE FUNCTION "gw_ledger".transaction_receipt_get(
  i_receipt_root BYTEA
) RETURNS JSONB AS $$
BEGIN
  RETURN WITH j_ret AS (  
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
  SELECT to_jsonb(j_ret) FROM j_ret;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.transaction/transaction-execute [315] 
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
    o_result := "gw_ledger".protocol_execute(i_context_root,(o_tx ->> 'op_root')::BYTEA);
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

-- gwdb.ledger.transaction/transaction-execute-signed [352] 
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



-- gwdb.ledger.scoped-ref/ScopedRef [17] 
DROP TABLE IF EXISTS "gw_ledger"."ScopedRef" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."ScopedRef" (
  "scope" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "root" BYTEA NOT NULL,
  "authorization_root" BYTEA NOT NULL,
  "version" BIGINT NOT NULL,
  "created_at" BIGINT NOT NULL,
  "updated_at" BIGINT NOT NULL,
  PRIMARY KEY (scope,name)
);

-- gwdb.ledger.scoped-ref/root-hex [31] 
CREATE OR REPLACE FUNCTION "gw_ledger".root_hex(
  i_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN CASE WHEN i_root IS NULL THEN null
  ELSE encode(i_root,'hex')
  END;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.scoped-ref/ref-part-valid [39] 
CREATE OR REPLACE FUNCTION "gw_ledger".ref_part_valid(
  i_value TEXT
) RETURNS BOOLEAN AS $$

  SELECT RETURN i_value IS NOT NULL AND regexp_match(i_value,'^[a-z0-9][a-z0-9._:/-]{0,255}$') IS NOT NULL;

$$ LANGUAGE 'sql' IMMUTABLE PARALLEL SAFE;

-- gwdb.ledger.scoped-ref/scoped-ref-lock-key [53] 
CREATE OR REPLACE FUNCTION "gw_ledger".scoped_ref_lock_key(
  i_scope TEXT,
  i_name TEXT
) RETURNS BIGINT AS $$

  SELECT RETURN hash_text_extended((length(i_scope))::TEXT || ':' || i_scope || ':' || i_name,0);

$$ LANGUAGE 'sql' IMMUTABLE PARALLEL SAFE;

-- gwdb.ledger.scoped-ref/scoped-ref-row [65] 
CREATE OR REPLACE FUNCTION "gw_ledger".scoped_ref_row(
  i_scope TEXT,
  i_name TEXT
) RETURNS JSONB AS $$
BEGIN
  RETURN WITH j_ret AS (  
    SELECT
      "scope",
      "name",
      "root",
      "authorization_root",
      "version",
      "created_at",
      "updated_at"
    FROM "gw_ledger"."ScopedRef"
    WHERE "scope" = i_scope AND "name" = i_name
    LIMIT 1)
  SELECT to_jsonb(j_ret) FROM j_ret;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.scoped-ref/scoped-ref-capabilities [73] 
CREATE OR REPLACE FUNCTION "gw_ledger".scoped_ref_capabilities() RETURNS JSONB AS $$
BEGIN
  RETURN jsonb_build_object(
    'backend_type',
    'postgresql',
    'backend_name',
    'ignatius-ledger',
    'backend_durability',
    'durable',
    'block_immutable',
    true,
    'block_verification',
    'required',
    'block_hash_algorithm',
    'sha-256',
    'ref_compare_and_set',
    true,
    'ref_consistency',
    'linearizable',
    'ref_authorization',
    'explicit'
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.scoped-ref/scoped-ref-read-error [90] 
CREATE OR REPLACE FUNCTION "gw_ledger".scoped_ref_read_error(
  i_scope TEXT,
  i_name TEXT,
  i_authorization_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  IF NOT "gw_ledger".ref_part_valid(i_scope) THEN
    RETURN 'storage/invalid-ref-scope';
  ELSIF NOT "gw_ledger".ref_part_valid(i_name) THEN
    RETURN 'storage/invalid-ref-name';
  ELSIF i_authorization_root is null  THEN
    RETURN 'storage/missing-ref-authorization';
  ELSIF "gw_ledger".cell_by_hash(i_authorization_root) is null  THEN
    RETURN 'storage/unknown-ref-authorization';
  ELSE
    RETURN null;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.scoped-ref/scoped-ref-update-error [109] 
CREATE OR REPLACE FUNCTION "gw_ledger".scoped_ref_update_error(
  i_scope TEXT,
  i_name TEXT,
  i_expected_root BYTEA,
  i_desired_root BYTEA,
  i_authorization_root BYTEA
) RETURNS TEXT AS $$

  DECLARE
    v_read_error TEXT;
  BEGIN
    v_read_error := "gw_ledger".scoped_ref_read_error(i_scope,i_name,i_authorization_root);
    IF v_read_error is not null  THEN
      RETURN v_read_error;
    ELSIF i_desired_root is null  THEN
      RETURN 'storage/missing-desired-ref-root';
    ELSIF "gw_ledger".cell_by_hash(i_desired_root) is null  THEN
      RETURN 'storage/unknown-desired-ref-root';
    ELSIF i_expected_root IS NOT NULL AND "gw_ledger".cell_by_hash(i_expected_root) IS NULL THEN
      RETURN 'storage/unknown-expected-ref-root';
    ELSE
      RETURN null;
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.scoped-ref/scoped-ref-error-result [136] 
CREATE OR REPLACE FUNCTION "gw_ledger".scoped_ref_error_result(
  i_error TEXT,
  i_scope TEXT,
  i_name TEXT
) RETURNS JSONB AS $$
BEGIN
  RETURN jsonb_build_object('status','error','error',i_error,'scope',i_scope,'name',i_name);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.scoped-ref/scoped-ref-value-result [147] 
CREATE OR REPLACE FUNCTION "gw_ledger".scoped_ref_value_result(
  i_status TEXT,
  i_scope TEXT,
  i_name TEXT,
  i_root BYTEA,
  i_version BIGINT,
  i_authorization_root BYTEA
) RETURNS JSONB AS $$
BEGIN
  RETURN jsonb_build_object(
    'status',
    i_status,
    'scope',
    i_scope,
    'name',
    i_name,
    'root',
    "gw_ledger".root_hex(i_root),
    'version',
    i_version,
    'authorization_root',
    "gw_ledger".root_hex(i_authorization_root)
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.scoped-ref/scoped-ref-read [165] 
CREATE OR REPLACE FUNCTION "gw_ledger".scoped_ref_read(
  i_scope TEXT,
  i_name TEXT,
  i_authorization_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    v_error TEXT;
  BEGIN
    v_error := "gw_ledger".scoped_ref_read_error(i_scope,i_name,i_authorization_root);
    IF v_error is not null  THEN
      RETURN "gw_ledger".scoped_ref_error_result(v_error,i_scope,i_name);
    END IF;
    DECLARE
      o_row JSONB;
    BEGIN
      o_row := "gw_ledger".scoped_ref_row(i_scope,i_name);
      RETURN CASE WHEN o_row IS NULL THEN "gw_ledger".scoped_ref_value_result('ok',i_scope,i_name,null,0,i_authorization_root)
      ELSE "gw_ledger".scoped_ref_value_result(
        'ok',
        i_scope,
        i_name,
        (o_row ->> 'root')::BYTEA,
        (o_row ->> 'version')::BIGINT,
        i_authorization_root
      )
      END;
    END;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.scoped-ref/scoped-ref-conflict-result [190] 
CREATE OR REPLACE FUNCTION "gw_ledger".scoped_ref_conflict_result(
  i_scope TEXT,
  i_name TEXT,
  i_expected_root BYTEA,
  i_actual_root BYTEA,
  i_desired_root BYTEA,
  i_version BIGINT
) RETURNS JSONB AS $$
BEGIN
  RETURN jsonb_build_object(
    'status',
    'conflict',
    'error',
    'storage/ref-conflict',
    'scope',
    i_scope,
    'name',
    i_name,
    'expected_root',
    "gw_ledger".root_hex(i_expected_root),
    'actual_root',
    "gw_ledger".root_hex(i_actual_root),
    'desired_root',
    "gw_ledger".root_hex(i_desired_root),
    'version',
    i_version
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.scoped-ref/scoped-ref-compare-and-set [210] 
CREATE OR REPLACE FUNCTION "gw_ledger".scoped_ref_compare_and_set(
  i_scope TEXT,
  i_name TEXT,
  i_expected_root BYTEA,
  i_desired_root BYTEA,
  i_authorization_root BYTEA
) RETURNS JSONB AS $$

  DECLARE
    v_error TEXT;
  BEGIN
    v_error := "gw_ledger".scoped_ref_update_error(
      i_scope,
      i_name,
      i_expected_root,
      i_desired_root,
      i_authorization_root
    );
    IF v_error is not null  THEN
      RETURN "gw_ledger".scoped_ref_error_result(v_error,i_scope,i_name);
    END IF;
    DECLARE
      o_current JSONB;
      v_actual_root BYTEA;
      v_actual_version BIGINT;
      v_lock_key BIGINT;
      v_matches BOOLEAN;
    BEGIN
      v_lock_key := "gw_ledger".scoped_ref_lock_key(i_scope,i_name);
      pg_advisory_xact_lock(v_lock_key);
      o_current := "gw_ledger".scoped_ref_row(i_scope,i_name);
      v_actual_root := CASE WHEN o_current IS NULL THEN null
      ELSE (o_current ->> 'root')::BYTEA
      END;
      v_actual_version := CASE WHEN o_current IS NULL THEN 0
      ELSE (o_current ->> 'version')::BIGINT
      END;
      v_matches := CASE WHEN i_expected_root IS NULL THEN v_actual_root IS NULL
      ELSE i_expected_root = v_actual_root
      END;
      IF NOT v_matches THEN
        RETURN "gw_ledger".scoped_ref_conflict_result(
          i_scope,
          i_name,
          i_expected_root,
          v_actual_root,
          i_desired_root,
          v_actual_version
        );
      END IF;
      IF o_current is null  THEN
        DECLARE
        o_created JSONB;
          v_now BIGINT;
      BEGIN
        v_now := (1000000 * extract(epoch FROM now()))::BIGINT;
          WITH j_ret AS (  
            INSERT INTO "gw_ledger"."ScopedRef" (
              "scope",
              "name",
              "root",
              "authorization_root",
              "version",
              "created_at",
              "updated_at"
            ) VALUES (
              (i_scope)::TEXT,
              (i_name)::TEXT,
              (i_desired_root)::BYTEA,
              (i_authorization_root)::BYTEA,
              (1)::BIGINT,
              (v_now)::BIGINT,
              (v_now)::BIGINT
            ) RETURNING
              "scope",
              "name",
              "root",
              "authorization_root",
              "version",
              "created_at",
              "updated_at")
          SELECT to_jsonb(j_ret) FROM j_ret INTO o_created;
          RETURN "gw_ledger".scoped_ref_value_result('ok',i_scope,i_name,i_desired_root,1,i_authorization_root);
      END;
      ELSE
        DECLARE
        o_updated JSONB;
          v_next_version BIGINT;
      BEGIN
        v_next_version := (v_actual_version + 1);
          WITH j_ret AS (  
            UPDATE "gw_ledger"."ScopedRef" SET
              "root" = (i_desired_root)::BYTEA,
              "authorization_root" = (i_authorization_root)::BYTEA,
              "version" = (v_next_version)::BIGINT,
              "updated_at" = ((1000000 * extract(epoch FROM now()))::BIGINT)::BIGINT
            WHERE "scope" = i_scope AND "name" = i_name AND "root" = i_expected_root
            RETURNING
              "scope",
              "name",
              "root",
              "authorization_root",
              "version",
              "created_at",
              "updated_at")
          SELECT to_jsonb(j_ret) FROM j_ret INTO o_updated;
          IF NOT (o_updated IS NOT NULL) THEN
            RAISE EXCEPTION USING
              DETAIL = (jsonb_build_object(
                'status',
                'error',
                'tag',
                'ledger/scoped_ref_update_lost',
                'data',
                null
              ))::TEXT,
              MESSAGE = 'ledger/scoped-ref-update-lost'
            ;
          END IF;
          RETURN "gw_ledger".scoped_ref_value_result(
            'ok',
            i_scope,
            i_name,
            i_desired_root,
            v_next_version,
            i_authorization_root
          );
      END;
      END IF;
    END;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/WorkspaceCommit [15] 
DROP TABLE IF EXISTS "gw_ledger"."WorkspaceCommit" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."WorkspaceCommit" (
  "commit_root" BYTEA PRIMARY KEY,
  "workspace_id_root" BYTEA NOT NULL,
  "workspace_root" BYTEA,
  "state_root" BYTEA NOT NULL,
  "operation_root" BYTEA,
  "merge_base_root" BYTEA,
  "merge_policy_root" BYTEA,
  "author_evidence_root" BYTEA NOT NULL,
  "execution_provenance_root" BYTEA,
  "parent_count" INTEGER NOT NULL
);

-- gwdb.ledger.workspace/WorkspaceCommitParent [29] 
DROP TABLE IF EXISTS "gw_ledger"."WorkspaceCommitParent" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."WorkspaceCommitParent" (
  "commit_root" BYTEA NOT NULL,
  "position" INTEGER NOT NULL,
  "parent_root" BYTEA NOT NULL,
  PRIMARY KEY (commit_root,position)
);

-- gwdb.ledger.workspace/keyword-root [36] 
CREATE OR REPLACE FUNCTION "gw_ledger".keyword_root(
  i_name TEXT
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".put_keyword(i_name);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/field [42] 
CREATE OR REPLACE FUNCTION "gw_ledger".field(
  i_record_root BYTEA,
  i_name TEXT
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".map_get(i_record_root,"gw_ledger".keyword_root(i_name));
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/optional-field [49] 
CREATE OR REPLACE FUNCTION "gw_ledger".optional_field(
  i_record_root BYTEA,
  i_name TEXT
) RETURNS BYTEA AS $$

  DECLARE
    v_root BYTEA;
  BEGIN
    v_root := "gw_ledger".field(i_record_root,i_name);
    RETURN CASE WHEN "gw_ledger".cell_type_tag(v_root) = 0 THEN null
    ELSE v_root
    END;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/record-kind [60] 
CREATE OR REPLACE FUNCTION "gw_ledger".record_kind(
  i_record_root BYTEA,
  i_kind TEXT
) RETURNS BOOLEAN AS $$

  DECLARE
    o_cell JSONB;
  BEGIN
    o_cell := "gw_ledger".cell_by_hash(i_record_root);
    RETURN o_cell IS NOT NULL AND ((o_cell ->> 'type_tag')::SMALLINT = 11) AND ("gw_ledger".field(i_record_root,'record/type') = "gw_ledger".keyword_root(i_kind));
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/record-version-one [71] 
CREATE OR REPLACE FUNCTION "gw_ledger".record_version_one(
  i_record_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    v_version_root BYTEA;
  BEGIN
    v_version_root := "gw_ledger".field(i_record_root,'record/version');
    RETURN v_version_root IS NOT NULL AND ("gw_ledger".cell_type_tag(v_version_root) = 2) AND ("gw_ledger".integer_bigint(v_version_root) = 1);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/optional-root [82] 
CREATE OR REPLACE FUNCTION "gw_ledger".optional_root(
  i_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN CASE WHEN i_root IS NULL THEN "gw_ledger".put_nil()
  ELSE i_root
  END;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/record-start [91] 
CREATE OR REPLACE FUNCTION "gw_ledger".record_start(
  i_kind TEXT
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".map_assoc(
    "gw_ledger".put_map(jsonb_build_array()),
    "gw_ledger".keyword_root('record/type'),
    "gw_ledger".keyword_root(i_kind)
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/record-assoc [101] 
CREATE OR REPLACE FUNCTION "gw_ledger".record_assoc(
  i_record_root BYTEA,
  i_name TEXT,
  i_value_root BYTEA
) RETURNS BYTEA AS $$
BEGIN
  RETURN "gw_ledger".map_assoc(i_record_root,"gw_ledger".keyword_root(i_name),i_value_root);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/workspace-commit-value [109] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_commit_value(
  i_workspace_id_root BYTEA,
  i_workspace_root BYTEA,
  i_parent_roots_root BYTEA,
  i_state_root BYTEA,
  i_operation_root BYTEA,
  i_merge_base_root BYTEA,
  i_merge_policy_root BYTEA,
  i_author_evidence_root BYTEA,
  i_execution_provenance_root BYTEA,
  i_metadata_root BYTEA,
  i_extensions_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_author BYTEA;
    v_extensions BYTEA;
    v_merge_base BYTEA;
    v_merge_policy BYTEA;
    v_operation BYTEA;
    v_parents BYTEA;
    v_provenance BYTEA;
    v_record BYTEA;
    v_state BYTEA;
    v_version BYTEA;
    v_workspace BYTEA;
    v_workspace_id BYTEA;
  BEGIN
    v_record := "gw_ledger".record_start('workspace/commit-candidate');
    v_version := "gw_ledger".record_assoc(v_record,'record/version',"gw_ledger".put_integer_number(1));
    v_extensions := "gw_ledger".record_assoc(v_version,'record/extensions',i_extensions_root);
    v_workspace_id := "gw_ledger".record_assoc(v_extensions,'workspace/id',i_workspace_id_root);
    v_workspace := "gw_ledger".record_assoc(
      v_workspace_id,
      'workspace/root',
      "gw_ledger".optional_root(i_workspace_root)
    );
    v_parents := "gw_ledger".record_assoc(v_workspace,'commit/parent-roots',i_parent_roots_root);
    v_state := "gw_ledger".record_assoc(v_parents,'commit/state-root',i_state_root);
    v_operation := "gw_ledger".record_assoc(
      v_state,
      'commit/operation-root',
      "gw_ledger".optional_root(i_operation_root)
    );
    v_merge_base := "gw_ledger".record_assoc(
      v_operation,
      'commit/merge-base-root',
      "gw_ledger".optional_root(i_merge_base_root)
    );
    v_merge_policy := "gw_ledger".record_assoc(
      v_merge_base,
      'commit/merge-policy-root',
      "gw_ledger".optional_root(i_merge_policy_root)
    );
    v_author := "gw_ledger".record_assoc(
      v_merge_policy,
      'commit/author-evidence',
      i_author_evidence_root
    );
    v_provenance := "gw_ledger".record_assoc(
      v_author,
      'commit/execution-provenance',
      "gw_ledger".optional_root(i_execution_provenance_root)
    );
    RETURN "gw_ledger".record_assoc(v_provenance,'commit/metadata',i_metadata_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/workspace-commit-row [168] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_commit_row(
  i_commit_root BYTEA
) RETURNS JSONB AS $$
BEGIN
  RETURN WITH j_ret AS (  
    SELECT
      "commit_root",
      "workspace_id_root",
      "workspace_root",
      "state_root",
      "operation_root",
      "merge_base_root",
      "merge_policy_root",
      "author_evidence_root",
      "execution_provenance_root",
      "parent_count"
    FROM "gw_ledger"."WorkspaceCommit"
    WHERE "commit_root" = i_commit_root
    LIMIT 1)
  SELECT to_jsonb(j_ret) FROM j_ret;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/workspace-commit-parent-count [175] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_commit_parent_count(
  i_commit_root BYTEA
) RETURNS INTEGER AS $$
BEGIN
  RETURN SELECT count(*) FROM "gw_ledger"."WorkspaceCommitParent"
  WHERE "commit_root" = i_commit_root;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/workspace-commit-parent-root [183] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_commit_parent_root(
  i_commit_root BYTEA,
  i_position INTEGER
) RETURNS BYTEA AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    WITH j_ret AS (  
      SELECT "commit_root","position","parent_root" FROM "gw_ledger"."WorkspaceCommitParent"
      WHERE "commit_root" = i_commit_root AND "position" = i_position
      LIMIT 1)
    SELECT to_jsonb(j_ret) FROM j_ret INTO o_row;
    RETURN CASE WHEN o_row IS NULL THEN null
    ELSE (o_row ->> 'parent_root')::BYTEA
    END;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/parent-seen-before [195] 
CREATE OR REPLACE FUNCTION "gw_ledger".parent_seen_before(
  i_parent_vector_root BYTEA,
  i_position INTEGER,
  i_parent_root BYTEA
) RETURNS BOOLEAN AS $$
BEGIN
  IF i_position <= 0 THEN
    RETURN false;
  ELSE
    DECLARE
    v_previous INTEGER;
      v_root BYTEA;
  BEGIN
    v_previous := (i_position - 1);
      v_root := "gw_ledger".cell_ref_child(i_parent_vector_root,v_previous,'element');
      RETURN (v_root = i_parent_root) OR "gw_ledger".parent_seen_before(i_parent_vector_root,v_previous,i_parent_root);
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/parent-error-at [214] 
CREATE OR REPLACE FUNCTION "gw_ledger".parent_error_at(
  i_commit_root BYTEA,
  i_workspace_id_root BYTEA,
  i_parent_vector_root BYTEA,
  i_position INTEGER,
  i_count INTEGER
) RETURNS TEXT AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN null;
  ELSE
    DECLARE
    o_parent JSONB;
      v_parent_root BYTEA;
  BEGIN
    v_parent_root := "gw_ledger".cell_ref_child(i_parent_vector_root,i_position,'element');
      o_parent := "gw_ledger".workspace_commit_row(v_parent_root);
      IF v_parent_root = i_commit_root THEN
        RETURN 'workspace/self-parent';
      ELSIF "gw_ledger".parent_seen_before(i_parent_vector_root,i_position,v_parent_root) THEN
        RETURN 'workspace/duplicate-parent-root';
      ELSIF o_parent is null  THEN
        RETURN 'workspace/missing-parent-commit';
      ELSIF NOT (i_workspace_id_root = (o_parent ->> 'workspace_id_root')::BYTEA) THEN
        RETURN 'workspace/parent-workspace-mismatch';
      ELSE
        RETURN "gw_ledger".parent_error_at(
          i_commit_root,
          i_workspace_id_root,
          i_parent_vector_root,
          i_position + 1,
          i_count
        );
      END IF;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/workspace-commit-root-seen-at [251] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_commit_root_seen_at(
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
    v_current := ((i_roots -> i_position) ->> 'commit_root')::BYTEA;
      IF v_current = i_root THEN
        RETURN true;
      ELSE
        RETURN "gw_ledger".workspace_commit_root_seen_at(i_roots,i_root,i_position + 1,i_count);
      END IF;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/workspace-commit-root-tail [271] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_commit_root_tail(
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
      RETURN "gw_ledger".workspace_commit_root_tail(i_roots,i_position + 1,i_count,v_next);
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/workspace-commit-parent-entries-at [287] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_commit_parent_entries_at(
  i_commit_root BYTEA,
  i_position INTEGER,
  i_count INTEGER,
  i_out JSONB
) RETURNS JSONB AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN i_out;
  ELSE
    DECLARE
    v_entry JSONB;
      v_next JSONB;
      v_parent_root BYTEA;
  BEGIN
    v_parent_root := "gw_ledger".workspace_commit_parent_root(i_commit_root,i_position);
      v_entry := jsonb_build_object('commit_root',v_parent_root);
      v_next := (i_out || jsonb_build_array(v_entry));
      RETURN "gw_ledger".workspace_commit_parent_entries_at(i_commit_root,i_position + 1,i_count,v_next);
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/workspace-commit-parent-entries [311] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_commit_parent_entries(
  i_commit_root BYTEA
) RETURNS JSONB AS $$
BEGIN
  RETURN "gw_ledger".workspace_commit_parent_entries_at(
    i_commit_root,
    0,
    "gw_ledger".workspace_commit_parent_count(i_commit_root),
    jsonb_build_array()
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/workspace-commit-ancestor-at [321] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_commit_ancestor_at(
  i_ancestor_root BYTEA,
  i_pending JSONB,
  i_seen JSONB
) RETURNS BOOLEAN AS $$

  DECLARE
    v_pending_count INTEGER;
  BEGIN
    v_pending_count := jsonb_array_length(i_pending);
    IF v_pending_count = 0 THEN
      RETURN false;
    ELSE
      DECLARE
      v_first JSONB;
        v_next_pending JSONB;
        v_next_seen JSONB;
        v_parents JSONB;
        v_root BYTEA;
        v_seen BOOLEAN;
        v_seen_count INTEGER;
        v_tail JSONB;
    BEGIN
      v_first := (i_pending -> 0);
        v_root := (v_first ->> 'commit_root')::BYTEA;
        v_seen_count := jsonb_array_length(i_seen);
        v_seen := "gw_ledger".workspace_commit_root_seen_at(i_seen,v_root,0,v_seen_count);
        v_tail := "gw_ledger".workspace_commit_root_tail(i_pending,1,v_pending_count,jsonb_build_array());
        v_parents := "gw_ledger".workspace_commit_parent_entries(v_root);
        v_next_pending := CASE WHEN v_seen THEN v_tail
        ELSE v_parents || v_tail
        END;
        v_next_seen := CASE WHEN v_seen THEN i_seen
        ELSE i_seen || jsonb_build_array(v_first)
        END;
        IF i_ancestor_root = v_root THEN
          RETURN true;
        ELSE
          RETURN "gw_ledger".workspace_commit_ancestor_at(i_ancestor_root,v_next_pending,v_next_seen);
        END IF;
    END;
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/workspace-commit-ancestor [363] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_commit_ancestor(
  i_ancestor_root BYTEA,
  i_descendant_root BYTEA
) RETURNS BOOLEAN AS $$
BEGIN
  IF i_ancestor_root = i_descendant_root THEN
    RETURN true;
  ELSIF "gw_ledger".workspace_commit_row(i_descendant_root) is null  THEN
    RETURN false;
  ELSE
    RETURN "gw_ledger".workspace_commit_ancestor_at(
      i_ancestor_root,
      jsonb_build_array(jsonb_build_object('commit_root',i_descendant_root)),
      jsonb_build_array()
    );
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/merge-base-valid-at [383] 
CREATE OR REPLACE FUNCTION "gw_ledger".merge_base_valid_at(
  i_merge_base_root BYTEA,
  i_parent_vector_root BYTEA,
  i_position INTEGER,
  i_count INTEGER
) RETURNS BOOLEAN AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN true;
  ELSE
    DECLARE
    v_parent_root BYTEA;
  BEGIN
    v_parent_root := "gw_ledger".cell_ref_child(i_parent_vector_root,i_position,'element');
      RETURN "gw_ledger".workspace_commit_ancestor(i_merge_base_root,v_parent_root) AND "gw_ledger".merge_base_valid_at(i_merge_base_root,i_parent_vector_root,i_position + 1,i_count);
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/workspace-commit-error [405] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_commit_error(
  i_commit_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  IF NOT "gw_ledger".record_kind(i_commit_root,'workspace/commit-candidate') THEN
    RETURN 'workspace/invalid-commit-record';
  ELSIF NOT "gw_ledger".record_version_one(i_commit_root) THEN
    RETURN 'workspace/unsupported-commit-version';
  ELSE
    DECLARE
    o_parent_vector JSONB;
      v_author_root BYTEA;
      v_merge_base_root BYTEA;
      v_merge_policy_root BYTEA;
      v_parent_count INTEGER;
      v_parent_vector_root BYTEA;
      v_state_root BYTEA;
      v_workspace_id_root BYTEA;
  BEGIN
    v_workspace_id_root := "gw_ledger".field(i_commit_root,'workspace/id');
      v_parent_vector_root := "gw_ledger".field(i_commit_root,'commit/parent-roots');
      v_state_root := "gw_ledger".field(i_commit_root,'commit/state-root');
      v_author_root := "gw_ledger".field(i_commit_root,'commit/author-evidence');
      v_merge_base_root := "gw_ledger".optional_field(i_commit_root,'commit/merge-base-root');
      v_merge_policy_root := "gw_ledger".optional_field(i_commit_root,'commit/merge-policy-root');
      o_parent_vector := "gw_ledger".cell_by_hash(v_parent_vector_root);
      v_parent_count := CASE WHEN o_parent_vector IS NULL THEN -1
      ELSE "gw_ledger".cell_ref_count(v_parent_vector_root,'element')
      END;
      IF "gw_ledger".cell_by_hash(v_workspace_id_root) is null  THEN
        RETURN 'workspace/missing-workspace-id';
      ELSIF o_parent_vector IS NULL OR NOT ((o_parent_vector ->> 'type_tag')::SMALLINT = 10) THEN
        RETURN 'workspace/parents-not-vector';
      ELSIF "gw_ledger".cell_by_hash(v_state_root) is null  THEN
        RETURN 'workspace/missing-state-root';
      ELSIF NOT "gw_ledger".record_kind(v_author_root,'ledger/evidence') THEN
        RETURN 'workspace/invalid-author-evidence';
      ELSIF "gw_ledger".cell_by_hash("gw_ledger".field(v_author_root,'ledger/signer')) is null  THEN
        RETURN 'workspace/missing-author-signer';
      ELSE
        DECLARE
        v_parent_error TEXT;
      BEGIN
        v_parent_error := "gw_ledger".parent_error_at(
            i_commit_root,
            v_workspace_id_root,
            v_parent_vector_root,
            0,
            v_parent_count
          );
          IF v_parent_error is not null  THEN
            RETURN v_parent_error;
          ELSIF v_parent_count >= 2 THEN
            IF v_merge_base_root is null  THEN
              RETURN 'workspace/missing-merge-base';
            ELSIF v_merge_policy_root is null  THEN
              RETURN 'workspace/missing-merge-policy';
            ELSIF "gw_ledger".workspace_commit_row(v_merge_base_root) is null  THEN
              RETURN 'workspace/unknown-merge-base';
            ELSIF NOT "gw_ledger".merge_base_valid_at(v_merge_base_root,v_parent_vector_root,0,v_parent_count) THEN
              RETURN 'workspace/invalid-merge-base';
            ELSE
              RETURN null;
            END IF;
          ELSIF v_merge_base_root IS NOT NULL OR v_merge_policy_root IS NOT NULL THEN
            RETURN 'workspace/non-merge-has-merge-fields';
          ELSE
            RETURN null;
          END IF;
      END;
      END IF;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/projection-parents-valid-at [490] 
CREATE OR REPLACE FUNCTION "gw_ledger".projection_parents_valid_at(
  i_commit_root BYTEA,
  i_parent_vector_root BYTEA,
  i_position INTEGER,
  i_count INTEGER
) RETURNS BOOLEAN AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN true;
  ELSE
    RETURN ("gw_ledger".workspace_commit_parent_root(i_commit_root,i_position) = "gw_ledger".cell_ref_child(i_parent_vector_root,i_position,'element')) AND "gw_ledger".projection_parents_valid_at(i_commit_root,i_parent_vector_root,i_position + 1,i_count);
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/optional-root-equal [511] 
CREATE OR REPLACE FUNCTION "gw_ledger".optional_root_equal(
  i_left BYTEA,
  i_right BYTEA
) RETURNS BOOLEAN AS $$
BEGIN
  RETURN CASE WHEN i_left IS NULL THEN i_right IS NULL
  WHEN i_right IS NULL THEN false
  ELSE i_left = i_right
  END;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/workspace-commit-valid [524] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_commit_valid(
  i_commit_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    o_row := "gw_ledger".workspace_commit_row(i_commit_root);
    IF o_row is null  THEN
      RETURN false;
    END IF;
    DECLARE
      v_parent_count INTEGER;
      v_parent_vector_root BYTEA;
    BEGIN
      v_parent_vector_root := "gw_ledger".field(i_commit_root,'commit/parent-roots');
      v_parent_count := "gw_ledger".cell_ref_count(v_parent_vector_root,'element');
      RETURN "gw_ledger".workspace_commit_error(i_commit_root) IS NULL AND ((o_row ->> 'workspace_id_root')::BYTEA = "gw_ledger".field(i_commit_root,'workspace/id')) AND "gw_ledger".optional_root_equal(
        (o_row ->> 'workspace_root')::BYTEA,
        "gw_ledger".optional_field(i_commit_root,'workspace/root')
      ) AND ((o_row ->> 'state_root')::BYTEA = "gw_ledger".field(i_commit_root,'commit/state-root')) AND "gw_ledger".optional_root_equal(
        (o_row ->> 'operation_root')::BYTEA,
        "gw_ledger".optional_field(i_commit_root,'commit/operation-root')
      ) AND "gw_ledger".optional_root_equal(
        (o_row ->> 'merge_base_root')::BYTEA,
        "gw_ledger".optional_field(i_commit_root,'commit/merge-base-root')
      ) AND "gw_ledger".optional_root_equal(
        (o_row ->> 'merge_policy_root')::BYTEA,
        "gw_ledger".optional_field(i_commit_root,'commit/merge-policy-root')
      ) AND ((o_row ->> 'author_evidence_root')::BYTEA = "gw_ledger".field(i_commit_root,'commit/author-evidence')) AND "gw_ledger".optional_root_equal(
        (o_row ->> 'execution_provenance_root')::BYTEA,
        "gw_ledger".optional_field(i_commit_root,'commit/execution-provenance')
      ) AND ((o_row ->> 'parent_count')::INTEGER = v_parent_count) AND ("gw_ledger".workspace_commit_parent_count(i_commit_root) = v_parent_count) AND "gw_ledger".projection_parents_valid_at(i_commit_root,v_parent_vector_root,0,v_parent_count);
    END;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/workspace-commit-parent-import-at [567] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_commit_parent_import_at(
  i_commit_root BYTEA,
  i_parent_vector_root BYTEA,
  i_position INTEGER,
  i_count INTEGER
) RETURNS BOOLEAN AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN true;
  ELSE
    DECLARE
    o_insert JSONB;
      v_parent_root BYTEA;
  BEGIN
    v_parent_root := "gw_ledger".cell_ref_child(i_parent_vector_root,i_position,'element');
      WITH j_ret AS (  
        INSERT INTO "gw_ledger"."WorkspaceCommitParent" ("commit_root","position","parent_root") VALUES (
          (i_commit_root)::BYTEA,
          (i_position)::INTEGER,
          (v_parent_root)::BYTEA
        ) RETURNING "commit_root","position","parent_root")
      SELECT to_jsonb(j_ret) FROM j_ret INTO o_insert;
      RETURN "gw_ledger".workspace_commit_parent_import_at(i_commit_root,i_parent_vector_root,i_position + 1,i_count);
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/workspace-commit-import [592] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_commit_import(
  i_commit_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_existing JSONB;
  BEGIN
    o_existing := "gw_ledger".workspace_commit_row(i_commit_root);
    IF o_existing is not null  THEN
      IF NOT ("gw_ledger".workspace_commit_valid(i_commit_root)) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object(
              'status',
              'error',
              'tag',
              'ledger/workspace_commit_projection_conflict',
              'data',
              null
            ))::TEXT,
          MESSAGE = 'ledger/workspace-commit-projection-conflict'
        ;
      END IF;
      RETURN i_commit_root;
    END IF;
    DECLARE
      o_insert JSONB;
      v_author_root BYTEA;
      v_error TEXT;
      v_merge_base_root BYTEA;
      v_merge_policy_root BYTEA;
      v_operation_root BYTEA;
      v_parent_count INTEGER;
      v_parent_vector_root BYTEA;
      v_provenance_root BYTEA;
      v_state_root BYTEA;
      v_workspace_id_root BYTEA;
      v_workspace_root BYTEA;
    BEGIN
      v_error := "gw_ledger".workspace_commit_error(i_commit_root);
      IF NOT (v_error IS NULL) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object(
            'status',
            'error',
            'tag',
            'ledger/invalid_workspace_commit',
            'data',
            v_error
          ))::TEXT,
          MESSAGE = 'ledger/invalid-workspace-commit'
        ;
      END IF;
      v_workspace_id_root := "gw_ledger".field(i_commit_root,'workspace/id');
      v_workspace_root := "gw_ledger".optional_field(i_commit_root,'workspace/root');
      v_parent_vector_root := "gw_ledger".field(i_commit_root,'commit/parent-roots');
      v_state_root := "gw_ledger".field(i_commit_root,'commit/state-root');
      v_operation_root := "gw_ledger".optional_field(i_commit_root,'commit/operation-root');
      v_merge_base_root := "gw_ledger".optional_field(i_commit_root,'commit/merge-base-root');
      v_merge_policy_root := "gw_ledger".optional_field(i_commit_root,'commit/merge-policy-root');
      v_author_root := "gw_ledger".field(i_commit_root,'commit/author-evidence');
      v_provenance_root := "gw_ledger".optional_field(i_commit_root,'commit/execution-provenance');
      v_parent_count := "gw_ledger".cell_ref_count(v_parent_vector_root,'element');
      WITH j_ret AS (  
        INSERT INTO "gw_ledger"."WorkspaceCommit" (
          "commit_root",
          "workspace_id_root",
          "workspace_root",
          "state_root",
          "operation_root",
          "merge_base_root",
          "merge_policy_root",
          "author_evidence_root",
          "execution_provenance_root",
          "parent_count"
        ) VALUES (
          (i_commit_root)::BYTEA,
          (v_workspace_id_root)::BYTEA,
          (v_workspace_root)::BYTEA,
          (v_state_root)::BYTEA,
          (v_operation_root)::BYTEA,
          (v_merge_base_root)::BYTEA,
          (v_merge_policy_root)::BYTEA,
          (v_author_root)::BYTEA,
          (v_provenance_root)::BYTEA,
          (v_parent_count)::INTEGER
        ) RETURNING
          "commit_root",
          "workspace_id_root",
          "workspace_root",
          "state_root",
          "operation_root",
          "merge_base_root",
          "merge_policy_root",
          "author_evidence_root",
          "execution_provenance_root",
          "parent_count")
      SELECT to_jsonb(j_ret) FROM j_ret INTO o_insert;
      "gw_ledger".workspace_commit_parent_import_at(i_commit_root,v_parent_vector_root,0,v_parent_count);
      RETURN i_commit_root;
    END;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace/workspace-commit-put [643] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_commit_put(
  i_workspace_id_root BYTEA,
  i_workspace_root BYTEA,
  i_parent_roots_root BYTEA,
  i_state_root BYTEA,
  i_operation_root BYTEA,
  i_merge_base_root BYTEA,
  i_merge_policy_root BYTEA,
  i_author_evidence_root BYTEA,
  i_execution_provenance_root BYTEA,
  i_metadata_root BYTEA,
  i_extensions_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_root BYTEA;
  BEGIN
    v_root := "gw_ledger".workspace_commit_value(
      i_workspace_id_root,
      i_workspace_root,
      i_parent_roots_root,
      i_state_root,
      i_operation_root,
      i_merge_base_root,
      i_merge_policy_root,
      i_author_evidence_root,
      i_execution_provenance_root,
      i_metadata_root,
      i_extensions_root
    );
    RETURN "gw_ledger".workspace_commit_import(v_root);
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
CREATE EXTENSION IF NOT EXISTS "pgsodium";

-- gwdb.ledger.workspace-admission/workspace-id-text [34] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_id_text(
  i_workspace_id_root BYTEA
) RETURNS TEXT AS $$

  DECLARE
    o_cell JSONB;
  BEGIN
    o_cell := "gw_ledger".cell_by_hash(i_workspace_id_root);
    IF NOT (o_cell IS NOT NULL AND ((o_cell ->> 'type_tag')::SMALLINT = 5)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_workspace_id','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-workspace-id'
      ;
    END IF;
    RETURN convert_from((o_cell ->> 'payload')::BYTEA,'UTF8');
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-admission/personal-scope [48] 
CREATE OR REPLACE FUNCTION "gw_ledger".personal_scope(
  i_workspace_id_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN 'workspace/' || "gw_ledger".workspace_id_text(i_workspace_id_root);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-admission/personal-name [55] 
CREATE OR REPLACE FUNCTION "gw_ledger".personal_name(
  i_address_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN 'user/' || encode(i_address_root,'hex');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-admission/workspace-ref-intent-value [63] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_ref_intent_value(
  i_workspace_id_root BYTEA,
  i_address_root BYTEA,
  i_expected_root BYTEA,
  i_desired_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_authority BYTEA;
    v_desired BYTEA;
    v_empty_map BYTEA;
    v_expected BYTEA;
    v_extensions BYTEA;
    v_name TEXT;
    v_name_record BYTEA;
    v_policy BYTEA;
    v_record BYTEA;
    v_scope TEXT;
    v_scope_record BYTEA;
    v_version BYTEA;
    v_workspace BYTEA;
  BEGIN
    v_scope := "gw_ledger".personal_scope(i_workspace_id_root);
    v_name := "gw_ledger".personal_name(i_address_root);
    v_empty_map := "gw_ledger".put_map(jsonb_build_array());
    v_record := "gw_ledger".record_start('workspace/ref-update-intent');
    v_version := "gw_ledger".record_assoc(v_record,'record/version',"gw_ledger".put_integer_number(1));
    v_extensions := "gw_ledger".record_assoc(v_version,'record/extensions',v_empty_map);
    v_workspace := "gw_ledger".record_assoc(v_extensions,'workspace/id',i_workspace_id_root);
    v_scope_record := "gw_ledger".record_assoc(v_workspace,'ref/scope',"gw_ledger".put_string(v_scope));
    v_name_record := "gw_ledger".record_assoc(v_scope_record,'ref/name',"gw_ledger".put_string(v_name));
    v_expected := "gw_ledger".record_assoc(
      v_name_record,
      'ref/expected-root',
      "gw_ledger".optional_root(i_expected_root)
    );
    v_desired := "gw_ledger".record_assoc(v_expected,'ref/desired-root',i_desired_root);
    v_authority := "gw_ledger".record_assoc(v_desired,'ref/authorization-root',i_address_root);
    v_policy := "gw_ledger".record_assoc(
      v_authority,
      'ref/policy',
      "gw_ledger".put_keyword('personal-fast-forward-v1')
    );
    RETURN "gw_ledger".record_assoc(v_policy,'ref/metadata',v_empty_map);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-admission/workspace-ref-intent-valid [110] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_ref_intent_valid(
  i_intent_root BYTEA,
  i_workspace_id_root BYTEA,
  i_address_root BYTEA,
  i_expected_root BYTEA,
  i_desired_root BYTEA
) RETURNS BOOLEAN AS $$
BEGIN
  RETURN i_intent_root = "gw_ledger".workspace_ref_intent_value(
    i_workspace_id_root,
    i_address_root,
    i_expected_root,
    i_desired_root
  );
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-admission/workspace-ref-transition-error [125] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_ref_transition_error(
  i_workspace_id_root BYTEA,
  i_expected_root BYTEA,
  i_desired_root BYTEA,
  i_address_root BYTEA
) RETURNS TEXT AS $$

  DECLARE
    o_desired JSONB;
    o_expected JSONB;
    o_workspace_id JSONB;
  BEGIN
    o_workspace_id := "gw_ledger".cell_by_hash(i_workspace_id_root);
    o_desired := "gw_ledger".workspace_commit_row(i_desired_root);
    o_expected := CASE WHEN i_expected_root IS NULL THEN null
    ELSE "gw_ledger".workspace_commit_row(i_expected_root)
    END;
    IF o_workspace_id IS NULL OR NOT ((o_workspace_id ->> 'type_tag')::SMALLINT = 5) THEN
      RETURN 'workspace/invalid-workspace-id';
    ELSIF NOT "gw_ledger".ref_part_valid("gw_ledger".personal_scope(i_workspace_id_root)) THEN
      RETURN 'workspace/invalid-personal-ref-scope';
    ELSIF NOT "gw_ledger".ref_part_valid("gw_ledger".personal_name(i_address_root)) THEN
      RETURN 'workspace/invalid-personal-ref-name';
    ELSIF i_desired_root is null  THEN
      RETURN 'workspace/missing-desired-commit-root';
    ELSIF o_desired is null  THEN
      RETURN 'workspace/desired-commit-not-found';
    ELSIF NOT "gw_ledger".workspace_commit_valid(i_desired_root) THEN
      RETURN 'workspace/invalid-desired-commit';
    ELSIF NOT (i_workspace_id_root = (o_desired ->> 'workspace_id_root')::BYTEA) THEN
      RETURN 'workspace/desired-commit-workspace-mismatch';
    ELSIF i_expected_root IS NOT NULL AND o_expected IS NULL THEN
      RETURN 'workspace/expected-commit-not-found';
    ELSIF i_expected_root IS NOT NULL AND NOT "gw_ledger".workspace_commit_valid(i_expected_root) THEN
      RETURN 'workspace/invalid-expected-commit';
    ELSIF i_expected_root IS NOT NULL AND NOT (i_workspace_id_root = (o_expected ->> 'workspace_id_root')::BYTEA) THEN
      RETURN 'workspace/expected-commit-workspace-mismatch';
    ELSIF i_expected_root IS NOT NULL AND (i_expected_root = i_desired_root) THEN
      RETURN 'workspace/noop-ref-update';
    ELSIF i_expected_root IS NOT NULL AND NOT "gw_ledger".workspace_commit_ancestor(i_expected_root,i_desired_root) THEN
      RETURN 'workspace/non-fast-forward-ref-update';
    ELSE
      RETURN null;
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-admission/workspace-ref-signing-request [197] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_ref_signing_request(
  i_network TEXT,
  i_public_key BYTEA,
  i_workspace_id_root BYTEA,
  i_expected_root BYTEA,
  i_desired_root BYTEA,
  i_cost_limit BIGINT
) RETURNS JSONB AS $$

  DECLARE
    o_head JSONB;
    v_account_root BYTEA;
    v_address_root BYTEA;
    v_controller_root BYTEA;
    v_expected_controller BYTEA;
    v_intent_root BYTEA;
    v_op_root BYTEA;
    v_payload BYTEA;
    v_runtime_root BYTEA;
    v_sequence BIGINT;
    v_state_root BYTEA;
    v_transition_error TEXT;
  BEGIN
    o_head := "gw_ledger".head_get(i_network);
    IF NOT (o_head IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/network_missing','data',null))::TEXT,
        MESSAGE = 'ledger/network-missing'
      ;
    END IF;
    IF NOT (i_cost_limit >= 1) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_cost_limit','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-cost-limit'
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
    v_transition_error := "gw_ledger".workspace_ref_transition_error(
      i_workspace_id_root,
      i_expected_root,
      i_desired_root,
      v_address_root
    );
    IF NOT (v_transition_error IS NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_workspace_ref_update',
          'data',
          v_transition_error
        ))::TEXT,
        MESSAGE = 'ledger/invalid-workspace-ref-update'
      ;
    END IF;
    v_intent_root := "gw_ledger".workspace_ref_intent_value(
      i_workspace_id_root,
      v_address_root,
      i_expected_root,
      i_desired_root
    );
    IF NOT ("gw_ledger".workspace_ref_intent_valid(
      v_intent_root,
      i_workspace_id_root,
      v_address_root,
      i_expected_root,
      i_desired_root
    )) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_workspace_ref_intent',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-workspace-ref-intent'
      ;
    END IF;
    v_op_root := "gw_ledger".constant(v_intent_root);
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
      'workspace_id_root',
      encode(i_workspace_id_root,'hex'),
      'scope',
      "gw_ledger".personal_scope(i_workspace_id_root),
      'name',
      "gw_ledger".personal_name(v_address_root),
      'expected_root',
      "gw_ledger".root_hex(i_expected_root),
      'desired_root',
      encode(i_desired_root,'hex'),
      'intent_root',
      encode(v_intent_root,'hex'),
      'operation_root',
      encode(v_op_root,'hex'),
      'signing_payload',
      encode(v_payload,'hex')
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-admission/workspace-ref-submit [261] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_ref_submit(
  i_network TEXT,
  i_public_key BYTEA,
  i_sequence BIGINT,
  i_workspace_id_root BYTEA,
  i_expected_root BYTEA,
  i_desired_root BYTEA,
  i_cost_limit BIGINT,
  i_signature BYTEA,
  i_timestamp BIGINT
) RETURNS JSONB AS $$

  DECLARE
    o_cas JSONB;
    o_head JSONB;
    v_account_root BYTEA;
    v_address_root BYTEA;
    v_cas_status TEXT;
    v_controller_root BYTEA;
    v_current_sequence BIGINT;
    v_expected_controller BYTEA;
    v_intent_root BYTEA;
    v_name TEXT;
    v_op_root BYTEA;
    v_previous_height BIGINT;
    v_previous_state BYTEA;
    v_runtime_root BYTEA;
    v_scope TEXT;
    v_signing_payload BYTEA;
    v_transition_error TEXT;
  BEGIN
    o_head := "gw_ledger".head_lock(i_network);
    IF NOT (o_head IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/network_missing','data',null))::TEXT,
        MESSAGE = 'ledger/network-missing'
      ;
    END IF;
    IF NOT (i_cost_limit >= 1) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_cost_limit','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-cost-limit'
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
    v_transition_error := "gw_ledger".workspace_ref_transition_error(
      i_workspace_id_root,
      i_expected_root,
      i_desired_root,
      v_address_root
    );
    IF NOT (v_transition_error IS NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_workspace_ref_update',
          'data',
          v_transition_error
        ))::TEXT,
        MESSAGE = 'ledger/invalid-workspace-ref-update'
      ;
    END IF;
    v_scope := "gw_ledger".personal_scope(i_workspace_id_root);
    v_name := "gw_ledger".personal_name(v_address_root);
    v_intent_root := "gw_ledger".workspace_ref_intent_value(
      i_workspace_id_root,
      v_address_root,
      i_expected_root,
      i_desired_root
    );
    IF NOT ("gw_ledger".workspace_ref_intent_valid(
      v_intent_root,
      i_workspace_id_root,
      v_address_root,
      i_expected_root,
      i_desired_root
    )) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_workspace_ref_intent',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-workspace-ref-intent'
      ;
    END IF;
    v_op_root := "gw_ledger".constant(v_intent_root);
    v_runtime_root := "gw_ledger".put_integer('1');
    v_signing_payload := "gw_ledger".transaction_signing_payload(
      i_network,
      v_address_root,
      i_sequence,
      v_op_root,
      null,
      i_cost_limit,
      v_runtime_root
    );
    IF NOT ("gw_ledger".signature_verify(i_signature,v_signing_payload,i_public_key)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_workspace_ref_signature',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-workspace-ref-signature'
      ;
    END IF;
    o_cas := "gw_ledger".scoped_ref_compare_and_set(v_scope,v_name,i_expected_root,i_desired_root,v_address_root);
    v_cas_status := (o_cas ->> 'status')::TEXT;
    IF NOT (v_cas_status = 'ok') THEN
      RETURN o_cas || jsonb_build_object(
        'address',
        encode(v_address_root,'hex'),
        'intent_root',
        encode(v_intent_root,'hex'),
        'sequence',
        i_sequence
      );
    END IF;
    DECLARE
      o_bound JSONB;
      o_receipt JSONB;
      v_block_root BYTEA;
      v_receipt_root BYTEA;
      v_state_root BYTEA;
      v_transaction_root BYTEA;
    BEGIN
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
      IF NOT (o_receipt IS NOT NULL) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_receipt','data',null))::TEXT,
          MESSAGE = 'ledger/missing-receipt'
        ;
      END IF;
      IF NOT (((o_receipt ->> 'status')::TEXT = 'ok') AND ((o_receipt ->> 'result_root')::BYTEA = v_intent_root)) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object(
            'status',
            'error',
            'tag',
            'ledger/workspace_ref_receipt_mismatch',
            'data',
            null
          ))::TEXT,
          MESSAGE = 'ledger/workspace-ref-receipt-mismatch'
        ;
      END IF;
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
        'status',
        'ok',
        'address',
        encode(v_address_root,'hex'),
        'sequence',
        i_sequence,
        'scope',
        v_scope,
        'name',
        v_name,
        'expected_root',
        "gw_ledger".root_hex(i_expected_root),
        'desired_root',
        encode(i_desired_root,'hex'),
        'ref_version',
        (o_cas ->> 'version')::BIGINT,
        'intent_root',
        encode(v_intent_root,'hex'),
        'transaction_root',
        encode(v_transaction_root,'hex'),
        'receipt_root',
        encode(v_receipt_root,'hex'),
        'result_root',
        encode((o_receipt ->> 'result_root')::BYTEA,'hex'),
        'state_root',
        encode(v_state_root,'hex'),
        'block_root',
        encode(v_block_root,'hex')
      );
    END;
  END;

$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pgsodium";

-- gwdb.ledger.workspace-proposal/proposal-scope [36] 
CREATE OR REPLACE FUNCTION "gw_ledger".proposal_scope(
  i_workspace_id_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN "gw_ledger".personal_scope(i_workspace_id_root);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-proposal/proposal-name [43] 
CREATE OR REPLACE FUNCTION "gw_ledger".proposal_name(
  i_desired_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN 'proposal/' || encode(i_desired_root,'hex');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-proposal/workspace-proposal-intent-value [51] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_proposal_intent_value(
  i_workspace_id_root BYTEA,
  i_address_root BYTEA,
  i_desired_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_authority BYTEA;
    v_desired BYTEA;
    v_empty_map BYTEA;
    v_expected BYTEA;
    v_extensions BYTEA;
    v_name TEXT;
    v_name_record BYTEA;
    v_policy BYTEA;
    v_record BYTEA;
    v_scope TEXT;
    v_scope_record BYTEA;
    v_version BYTEA;
    v_workspace BYTEA;
  BEGIN
    v_scope := "gw_ledger".proposal_scope(i_workspace_id_root);
    v_name := "gw_ledger".proposal_name(i_desired_root);
    v_empty_map := "gw_ledger".put_map(jsonb_build_array());
    v_record := "gw_ledger".record_start('workspace/ref-update-intent');
    v_version := "gw_ledger".record_assoc(v_record,'record/version',"gw_ledger".put_integer_number(1));
    v_extensions := "gw_ledger".record_assoc(v_version,'record/extensions',v_empty_map);
    v_workspace := "gw_ledger".record_assoc(v_extensions,'workspace/id',i_workspace_id_root);
    v_scope_record := "gw_ledger".record_assoc(v_workspace,'ref/scope',"gw_ledger".put_string(v_scope));
    v_name_record := "gw_ledger".record_assoc(v_scope_record,'ref/name',"gw_ledger".put_string(v_name));
    v_expected := "gw_ledger".record_assoc(v_name_record,'ref/expected-root',"gw_ledger".put_nil());
    v_desired := "gw_ledger".record_assoc(v_expected,'ref/desired-root',i_desired_root);
    v_authority := "gw_ledger".record_assoc(v_desired,'ref/authorization-root',i_address_root);
    v_policy := "gw_ledger".record_assoc(
      v_authority,
      'ref/policy',
      "gw_ledger".put_keyword('proposal-publication-v1')
    );
    RETURN "gw_ledger".record_assoc(v_policy,'ref/metadata',v_empty_map);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-proposal/workspace-proposal-intent-valid [96] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_proposal_intent_valid(
  i_intent_root BYTEA,
  i_workspace_id_root BYTEA,
  i_address_root BYTEA,
  i_desired_root BYTEA
) RETURNS BOOLEAN AS $$
BEGIN
  RETURN i_intent_root = "gw_ledger".workspace_proposal_intent_value(i_workspace_id_root,i_address_root,i_desired_root);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-proposal/workspace-proposal-transition-error [109] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_proposal_transition_error(
  i_workspace_id_root BYTEA,
  i_desired_root BYTEA
) RETURNS TEXT AS $$

  DECLARE
    o_desired JSONB;
    o_workspace_id JSONB;
  BEGIN
    o_workspace_id := "gw_ledger".cell_by_hash(i_workspace_id_root);
    o_desired := "gw_ledger".workspace_commit_row(i_desired_root);
    IF o_workspace_id IS NULL OR NOT ((o_workspace_id ->> 'type_tag')::SMALLINT = 5) THEN
      RETURN 'workspace/invalid-workspace-id';
    ELSIF NOT "gw_ledger".ref_part_valid("gw_ledger".proposal_scope(i_workspace_id_root)) THEN
      RETURN 'workspace/invalid-proposal-ref-scope';
    ELSIF i_desired_root is null  THEN
      RETURN 'workspace/missing-desired-commit-root';
    ELSIF NOT "gw_ledger".ref_part_valid("gw_ledger".proposal_name(i_desired_root)) THEN
      RETURN 'workspace/invalid-proposal-ref-name';
    ELSIF o_desired is null  THEN
      RETURN 'workspace/desired-commit-not-found';
    ELSIF NOT "gw_ledger".workspace_commit_valid(i_desired_root) THEN
      RETURN 'workspace/invalid-desired-commit';
    ELSIF NOT (i_workspace_id_root = (o_desired ->> 'workspace_id_root')::BYTEA) THEN
      RETURN 'workspace/desired-commit-workspace-mismatch';
    ELSE
      RETURN null;
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-proposal/workspace-proposal-signing-request [149] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_proposal_signing_request(
  i_network TEXT,
  i_public_key BYTEA,
  i_workspace_id_root BYTEA,
  i_desired_root BYTEA,
  i_cost_limit BIGINT
) RETURNS JSONB AS $$

  DECLARE
    o_head JSONB;
    v_account_root BYTEA;
    v_address_root BYTEA;
    v_controller_root BYTEA;
    v_expected_controller BYTEA;
    v_intent_root BYTEA;
    v_op_root BYTEA;
    v_payload BYTEA;
    v_runtime_root BYTEA;
    v_sequence BIGINT;
    v_state_root BYTEA;
    v_transition_error TEXT;
  BEGIN
    o_head := "gw_ledger".head_get(i_network);
    IF NOT (o_head IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/network_missing','data',null))::TEXT,
        MESSAGE = 'ledger/network-missing'
      ;
    END IF;
    IF NOT (i_cost_limit >= 1) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_cost_limit','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-cost-limit'
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
    v_transition_error := "gw_ledger".workspace_proposal_transition_error(i_workspace_id_root,i_desired_root);
    IF NOT (v_transition_error IS NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_workspace_proposal',
          'data',
          v_transition_error
        ))::TEXT,
        MESSAGE = 'ledger/invalid-workspace-proposal'
      ;
    END IF;
    v_intent_root := "gw_ledger".workspace_proposal_intent_value(i_workspace_id_root,v_address_root,i_desired_root);
    IF NOT ("gw_ledger".workspace_proposal_intent_valid(
      v_intent_root,
      i_workspace_id_root,
      v_address_root,
      i_desired_root
    )) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_workspace_proposal_intent',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-workspace-proposal-intent'
      ;
    END IF;
    v_op_root := "gw_ledger".constant(v_intent_root);
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
      'workspace_id_root',
      encode(i_workspace_id_root,'hex'),
      'scope',
      "gw_ledger".proposal_scope(i_workspace_id_root),
      'name',
      "gw_ledger".proposal_name(i_desired_root),
      'expected_root',
      null,
      'desired_root',
      encode(i_desired_root,'hex'),
      'policy',
      'proposal-publication-v1',
      'intent_root',
      encode(v_intent_root,'hex'),
      'operation_root',
      encode(v_op_root,'hex'),
      'signing_payload',
      encode(v_payload,'hex')
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-proposal/workspace-proposal-submit [211] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_proposal_submit(
  i_network TEXT,
  i_public_key BYTEA,
  i_sequence BIGINT,
  i_workspace_id_root BYTEA,
  i_desired_root BYTEA,
  i_cost_limit BIGINT,
  i_signature BYTEA,
  i_timestamp BIGINT
) RETURNS JSONB AS $$

  DECLARE
    o_cas JSONB;
    o_head JSONB;
    v_account_root BYTEA;
    v_address_root BYTEA;
    v_cas_status TEXT;
    v_controller_root BYTEA;
    v_current_sequence BIGINT;
    v_expected_controller BYTEA;
    v_intent_root BYTEA;
    v_name TEXT;
    v_op_root BYTEA;
    v_previous_height BIGINT;
    v_previous_state BYTEA;
    v_runtime_root BYTEA;
    v_scope TEXT;
    v_signing_payload BYTEA;
    v_transition_error TEXT;
  BEGIN
    o_head := "gw_ledger".head_lock(i_network);
    IF NOT (o_head IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/network_missing','data',null))::TEXT,
        MESSAGE = 'ledger/network-missing'
      ;
    END IF;
    IF NOT (i_cost_limit >= 1) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_cost_limit','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-cost-limit'
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
    v_transition_error := "gw_ledger".workspace_proposal_transition_error(i_workspace_id_root,i_desired_root);
    IF NOT (v_transition_error IS NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_workspace_proposal',
          'data',
          v_transition_error
        ))::TEXT,
        MESSAGE = 'ledger/invalid-workspace-proposal'
      ;
    END IF;
    v_scope := "gw_ledger".proposal_scope(i_workspace_id_root);
    v_name := "gw_ledger".proposal_name(i_desired_root);
    v_intent_root := "gw_ledger".workspace_proposal_intent_value(i_workspace_id_root,v_address_root,i_desired_root);
    IF NOT ("gw_ledger".workspace_proposal_intent_valid(
      v_intent_root,
      i_workspace_id_root,
      v_address_root,
      i_desired_root
    )) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_workspace_proposal_intent',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-workspace-proposal-intent'
      ;
    END IF;
    v_op_root := "gw_ledger".constant(v_intent_root);
    v_runtime_root := "gw_ledger".put_integer('1');
    v_signing_payload := "gw_ledger".transaction_signing_payload(
      i_network,
      v_address_root,
      i_sequence,
      v_op_root,
      null,
      i_cost_limit,
      v_runtime_root
    );
    IF NOT ("gw_ledger".signature_verify(i_signature,v_signing_payload,i_public_key)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_workspace_proposal_signature',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-workspace-proposal-signature'
      ;
    END IF;
    o_cas := "gw_ledger".scoped_ref_compare_and_set(v_scope,v_name,null,i_desired_root,v_address_root);
    v_cas_status := (o_cas ->> 'status')::TEXT;
    IF NOT (v_cas_status = 'ok') THEN
      RETURN o_cas || jsonb_build_object(
        'address',
        encode(v_address_root,'hex'),
        'policy',
        'proposal-publication-v1',
        'intent_root',
        encode(v_intent_root,'hex'),
        'sequence',
        i_sequence
      );
    END IF;
    DECLARE
      o_bound JSONB;
      o_receipt JSONB;
      v_block_root BYTEA;
      v_receipt_root BYTEA;
      v_state_root BYTEA;
      v_transaction_root BYTEA;
    BEGIN
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
      IF NOT (o_receipt IS NOT NULL) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_receipt','data',null))::TEXT,
          MESSAGE = 'ledger/missing-receipt'
        ;
      END IF;
      IF NOT (((o_receipt ->> 'status')::TEXT = 'ok') AND ((o_receipt ->> 'result_root')::BYTEA = v_intent_root)) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object(
            'status',
            'error',
            'tag',
            'ledger/workspace_proposal_receipt_mismatch',
            'data',
            null
          ))::TEXT,
          MESSAGE = 'ledger/workspace-proposal-receipt-mismatch'
        ;
      END IF;
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
        'status',
        'ok',
        'address',
        encode(v_address_root,'hex'),
        'sequence',
        i_sequence,
        'scope',
        v_scope,
        'name',
        v_name,
        'expected_root',
        null,
        'desired_root',
        encode(i_desired_root,'hex'),
        'policy',
        'proposal-publication-v1',
        'ref_version',
        (o_cas ->> 'version')::BIGINT,
        'intent_root',
        encode(v_intent_root,'hex'),
        'transaction_root',
        encode(v_transaction_root,'hex'),
        'receipt_root',
        encode(v_receipt_root,'hex'),
        'result_root',
        encode((o_receipt ->> 'result_root')::BYTEA,'hex'),
        'state_root',
        encode(v_state_root,'hex'),
        'block_root',
        encode(v_block_root,'hex')
      );
    END;
  END;

$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pgsodium";

-- gwdb.ledger.workspace-review/WorkspaceReview [38] 
DROP TABLE IF EXISTS "gw_ledger"."WorkspaceReview" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."WorkspaceReview" (
  "review_root" BYTEA PRIMARY KEY,
  "workspace_id_root" BYTEA NOT NULL,
  "candidate_root" BYTEA NOT NULL,
  "reviewer_root" BYTEA NOT NULL,
  "decision" TEXT NOT NULL,
  "recorded_at" BIGINT NOT NULL
);

-- gwdb.ledger.workspace-review/review-decision-valid [48] 
CREATE OR REPLACE FUNCTION "gw_ledger".review_decision_valid(
  i_decision TEXT
) RETURNS BOOLEAN AS $$
BEGIN
  RETURN (i_decision = 'approve') OR (i_decision = 'reject') OR (i_decision = 'withdraw');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-review/review-id [57] 
CREATE OR REPLACE FUNCTION "gw_ledger".review_id(
  i_candidate_root BYTEA,
  i_reviewer_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN 'review/' || encode(i_candidate_root,'hex') || '/' || encode(i_reviewer_root,'hex');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-review/review-ref-name [66] 
CREATE OR REPLACE FUNCTION "gw_ledger".review_ref_name(
  i_candidate_root BYTEA,
  i_reviewer_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN "gw_ledger".review_id(i_candidate_root,i_reviewer_root);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-review/review-subject-id [72] 
CREATE OR REPLACE FUNCTION "gw_ledger".review_subject_id(
  i_candidate_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN "gw_ledger".proposal_name(i_candidate_root);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-review/review-recorded-evidence-value [79] 
CREATE OR REPLACE FUNCTION "gw_ledger".review_recorded_evidence_value(
  i_reviewer_root BYTEA,
  i_recorded_at BIGINT
) RETURNS BYTEA AS $$

  DECLARE
    v_contract BYTEA;
    v_empty_map BYTEA;
    v_extensions BYTEA;
    v_head BYTEA;
    v_record BYTEA;
    v_signer BYTEA;
    v_template BYTEA;
    v_timestamp BYTEA;
    v_transaction BYTEA;
    v_version BYTEA;
  BEGIN
    v_empty_map := "gw_ledger".put_map(jsonb_build_array());
    v_record := "gw_ledger".record_start('ledger/evidence');
    v_version := "gw_ledger".record_assoc(v_record,'record/version',"gw_ledger".put_integer_number(1));
    v_extensions := "gw_ledger".record_assoc(v_version,'record/extensions',v_empty_map);
    v_signer := "gw_ledger".record_assoc(v_extensions,'ledger/signer',i_reviewer_root);
    v_transaction := "gw_ledger".record_assoc(v_signer,'ledger/transaction-root',"gw_ledger".put_nil());
    v_timestamp := "gw_ledger".record_assoc(
      v_transaction,
      'ledger/timestamp',
      "gw_ledger".put_integer_number(i_recorded_at)
    );
    v_head := "gw_ledger".record_assoc(v_timestamp,'ledger/previous-head-root',"gw_ledger".put_nil());
    v_contract := "gw_ledger".record_assoc(v_head,'ledger/contract-root',"gw_ledger".put_nil());
    v_template := "gw_ledger".record_assoc(v_contract,'ledger/template-root',"gw_ledger".put_nil());
    RETURN "gw_ledger".record_assoc(v_template,'ledger/global-state-root',"gw_ledger".put_nil());
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-review/workspace-review-value [117] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_review_value(
  i_candidate_root BYTEA,
  i_reviewer_root BYTEA,
  i_decision TEXT,
  i_recorded_at BIGINT
) RETURNS BYTEA AS $$

  DECLARE
    v_decision BYTEA;
    v_empty_map BYTEA;
    v_empty_vector BYTEA;
    v_evidence BYTEA;
    v_evidence_roots BYTEA;
    v_extensions BYTEA;
    v_id BYTEA;
    v_process_id BYTEA;
    v_process_root BYTEA;
    v_record BYTEA;
    v_subject_id BYTEA;
    v_subject_root BYTEA;
    v_version BYTEA;
  BEGIN
    v_empty_map := "gw_ledger".put_map(jsonb_build_array());
    v_empty_vector := "gw_ledger".put_vector(jsonb_build_array());
    v_record := "gw_ledger".record_start('review/decision');
    v_version := "gw_ledger".record_assoc(v_record,'record/version',"gw_ledger".put_integer_number(1));
    v_extensions := "gw_ledger".record_assoc(v_version,'record/extensions',v_empty_map);
    v_id := "gw_ledger".record_assoc(
      v_extensions,
      'review/id',
      "gw_ledger".put_string("gw_ledger".review_id(i_candidate_root,i_reviewer_root))
    );
    v_subject_id := "gw_ledger".record_assoc(
      v_id,
      'review/subject-id',
      "gw_ledger".put_string("gw_ledger".review_subject_id(i_candidate_root))
    );
    v_subject_root := "gw_ledger".record_assoc(v_subject_id,'review/subject-root',i_candidate_root);
    v_decision := "gw_ledger".record_assoc(
      v_subject_root,
      'review/decision',
      "gw_ledger".put_keyword(i_decision)
    );
    v_evidence_roots := "gw_ledger".record_assoc(v_decision,'review/evidence-roots',v_empty_vector);
    v_process_id := "gw_ledger".record_assoc(
      v_evidence_roots,
      'review/process-run-id',
      "gw_ledger".put_nil()
    );
    v_process_root := "gw_ledger".record_assoc(v_process_id,'review/process-run-root',"gw_ledger".put_nil());
    v_evidence := "gw_ledger".record_assoc(
      v_process_root,
      'review/recorded-evidence',
      "gw_ledger".review_recorded_evidence_value(i_reviewer_root,i_recorded_at)
    );
    RETURN "gw_ledger".record_assoc(v_evidence,'review/metadata',v_empty_map);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-review/workspace-review-row [171] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_review_row(
  i_review_root BYTEA
) RETURNS JSONB AS $$
BEGIN
  RETURN WITH j_ret AS (  
    SELECT
      "review_root",
      "workspace_id_root",
      "candidate_root",
      "reviewer_root",
      "decision",
      "recorded_at"
    FROM "gw_ledger"."WorkspaceReview"
    WHERE "review_root" = i_review_root
    LIMIT 1)
  SELECT to_jsonb(j_ret) FROM j_ret;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-review/review-decision-text [178] 
CREATE OR REPLACE FUNCTION "gw_ledger".review_decision_text(
  i_decision_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN CASE WHEN i_decision_root = "gw_ledger".keyword_root('approve') THEN 'approve'
  WHEN i_decision_root = "gw_ledger".keyword_root('reject') THEN 'reject'
  WHEN i_decision_root = "gw_ledger".keyword_root('withdraw') THEN 'withdraw'
  ELSE null
  END;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-review/workspace-review-error [194] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_review_error(
  i_review_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  IF NOT "gw_ledger".record_kind(i_review_root,'review/decision') THEN
    RETURN 'workspace/invalid-review-record';
  ELSIF NOT "gw_ledger".record_version_one(i_review_root) THEN
    RETURN 'workspace/unsupported-review-version';
  ELSE
    DECLARE
    o_candidate JSONB;
      o_evidence_roots JSONB;
      o_recorded_at JSONB;
      v_candidate_root BYTEA;
      v_decision TEXT;
      v_decision_root BYTEA;
      v_empty_map BYTEA;
      v_evidence_roots BYTEA;
      v_extensions_root BYTEA;
      v_id_root BYTEA;
      v_metadata_root BYTEA;
      v_process_id BYTEA;
      v_process_root BYTEA;
      v_recorded_at_root BYTEA;
      v_recorded_evidence BYTEA;
      v_reviewer_root BYTEA;
      v_subject_id_root BYTEA;
  BEGIN
    v_candidate_root := "gw_ledger".field(i_review_root,'review/subject-root');
      o_candidate := "gw_ledger".workspace_commit_row(v_candidate_root);
      v_id_root := "gw_ledger".field(i_review_root,'review/id');
      v_subject_id_root := "gw_ledger".field(i_review_root,'review/subject-id');
      v_decision_root := "gw_ledger".field(i_review_root,'review/decision');
      v_decision := "gw_ledger".review_decision_text(v_decision_root);
      v_evidence_roots := "gw_ledger".field(i_review_root,'review/evidence-roots');
      o_evidence_roots := "gw_ledger".cell_by_hash(v_evidence_roots);
      v_process_id := "gw_ledger".optional_field(i_review_root,'review/process-run-id');
      v_process_root := "gw_ledger".optional_field(i_review_root,'review/process-run-root');
      v_recorded_evidence := "gw_ledger".field(i_review_root,'review/recorded-evidence');
      v_reviewer_root := "gw_ledger".field(v_recorded_evidence,'ledger/signer');
      v_recorded_at_root := "gw_ledger".field(v_recorded_evidence,'ledger/timestamp');
      o_recorded_at := "gw_ledger".cell_by_hash(v_recorded_at_root);
      v_metadata_root := "gw_ledger".field(i_review_root,'review/metadata');
      v_extensions_root := "gw_ledger".field(i_review_root,'record/extensions');
      v_empty_map := "gw_ledger".put_map(jsonb_build_array());
      IF o_candidate is null  THEN
        RETURN 'workspace/review-candidate-not-found';
      ELSIF NOT "gw_ledger".workspace_commit_valid(v_candidate_root) THEN
        RETURN 'workspace/invalid-review-candidate';
      ELSIF "gw_ledger".cell_by_hash(v_id_root) IS NULL OR NOT ("gw_ledger".cell_type_tag(v_id_root) = 5) THEN
        RETURN 'workspace/invalid-review-id';
      ELSIF "gw_ledger".cell_by_hash(v_subject_id_root) IS NULL OR NOT ("gw_ledger".cell_type_tag(v_subject_id_root) = 5) THEN
        RETURN 'workspace/invalid-review-subject-id';
      ELSIF v_decision is null  THEN
        RETURN 'workspace/invalid-review-decision';
      ELSIF o_evidence_roots IS NULL OR NOT ((o_evidence_roots ->> 'type_tag')::SMALLINT = 10) OR NOT ("gw_ledger".cell_ref_count(v_evidence_roots,'element') = 0) THEN
        RETURN 'workspace/review-evidence-roots-not-supported';
      ELSIF v_process_id is not null  THEN
        RETURN 'workspace/review-process-run-not-supported';
      ELSIF v_process_root is not null  THEN
        RETURN 'workspace/review-process-run-not-supported';
      ELSIF NOT "gw_ledger".record_kind(v_recorded_evidence,'ledger/evidence') THEN
        RETURN 'workspace/invalid-review-recorded-evidence';
      ELSIF NOT "gw_ledger".record_version_one(v_recorded_evidence) THEN
        RETURN 'workspace/unsupported-review-evidence-version';
      ELSIF "gw_ledger".cell_by_hash(v_reviewer_root) is null  THEN
        RETURN 'workspace/missing-reviewer';
      ELSIF o_recorded_at IS NULL OR NOT ((o_recorded_at ->> 'type_tag')::SMALLINT = 2) THEN
        RETURN 'workspace/invalid-review-recorded-at';
      ELSIF "gw_ledger".optional_field(v_recorded_evidence,'ledger/transaction-root') is not null  THEN
        RETURN 'workspace/review-transaction-evidence-not-supported';
      ELSIF "gw_ledger".optional_field(v_recorded_evidence,'ledger/previous-head-root') is not null  THEN
        RETURN 'workspace/review-head-evidence-not-supported';
      ELSIF "gw_ledger".optional_field(v_recorded_evidence,'ledger/contract-root') is not null  THEN
        RETURN 'workspace/review-contract-evidence-not-supported';
      ELSIF "gw_ledger".optional_field(v_recorded_evidence,'ledger/template-root') is not null  THEN
        RETURN 'workspace/review-template-evidence-not-supported';
      ELSIF "gw_ledger".optional_field(v_recorded_evidence,'ledger/global-state-root') is not null  THEN
        RETURN 'workspace/review-state-evidence-not-supported';
      ELSIF NOT (v_metadata_root = v_empty_map) THEN
        RETURN 'workspace/review-metadata-not-supported';
      ELSIF NOT (v_extensions_root = v_empty_map) THEN
        RETURN 'workspace/review-extensions-not-supported';
      ELSE
        DECLARE
        v_reconstructed BYTEA;
          v_recorded_at BIGINT;
      BEGIN
        v_recorded_at := "gw_ledger".integer_bigint(v_recorded_at_root);
          v_reconstructed := "gw_ledger".workspace_review_value(v_candidate_root,v_reviewer_root,v_decision,v_recorded_at);
          IF v_recorded_at < 0 THEN
            RETURN 'workspace/invalid-review-recorded-at';
          ELSIF NOT (v_id_root = "gw_ledger".put_string("gw_ledger".review_id(v_candidate_root,v_reviewer_root))) THEN
            RETURN 'workspace/review-id-not-derived';
          ELSIF NOT (v_subject_id_root = "gw_ledger".put_string("gw_ledger".review_subject_id(v_candidate_root))) THEN
            RETURN 'workspace/review-subject-id-not-proposal';
          ELSIF NOT (v_recorded_evidence = "gw_ledger".review_recorded_evidence_value(v_reviewer_root,v_recorded_at)) THEN
            RETURN 'workspace/noncanonical-review-evidence';
          ELSIF NOT (i_review_root = v_reconstructed) THEN
            RETURN 'workspace/noncanonical-review';
          ELSE
            RETURN null;
          END IF;
      END;
      END IF;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-review/workspace-review-valid [355] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_review_valid(
  i_review_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    o_row := "gw_ledger".workspace_review_row(i_review_root);
    IF o_row is null  THEN
      RETURN false;
    END IF;
    DECLARE
      v_candidate_root BYTEA;
      v_decision TEXT;
      v_recorded_at BIGINT;
      v_reviewer_root BYTEA;
    BEGIN
      v_candidate_root := (o_row ->> 'candidate_root')::BYTEA;
      v_reviewer_root := (o_row ->> 'reviewer_root')::BYTEA;
      v_decision := (o_row ->> 'decision')::TEXT;
      v_recorded_at := (o_row ->> 'recorded_at')::BIGINT;
      RETURN "gw_ledger".workspace_review_error(i_review_root) IS NULL AND ((o_row ->> 'workspace_id_root')::BYTEA = ("gw_ledger".workspace_commit_row(v_candidate_root) ->> 'workspace_id_root')::BYTEA) AND (i_review_root = "gw_ledger".workspace_review_value(v_candidate_root,v_reviewer_root,v_decision,v_recorded_at));
    END;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-review/workspace-review-import [383] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_review_import(
  i_review_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_existing JSONB;
  BEGIN
    o_existing := "gw_ledger".workspace_review_row(i_review_root);
    IF o_existing is not null  THEN
      IF NOT ("gw_ledger".workspace_review_valid(i_review_root)) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object(
              'status',
              'error',
              'tag',
              'ledger/workspace_review_projection_conflict',
              'data',
              null
            ))::TEXT,
          MESSAGE = 'ledger/workspace-review-projection-conflict'
        ;
      END IF;
      RETURN i_review_root;
    END IF;
    DECLARE
      o_candidate JSONB;
      o_insert JSONB;
      v_candidate_root BYTEA;
      v_decision TEXT;
      v_error TEXT;
      v_evidence_root BYTEA;
      v_recorded_at BIGINT;
      v_reviewer_root BYTEA;
    BEGIN
      v_error := "gw_ledger".workspace_review_error(i_review_root);
      IF NOT (v_error IS NULL) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object(
            'status',
            'error',
            'tag',
            'ledger/invalid_workspace_review',
            'data',
            v_error
          ))::TEXT,
          MESSAGE = 'ledger/invalid-workspace-review'
        ;
      END IF;
      v_candidate_root := "gw_ledger".field(i_review_root,'review/subject-root');
      o_candidate := "gw_ledger".workspace_commit_row(v_candidate_root);
      v_evidence_root := "gw_ledger".field(i_review_root,'review/recorded-evidence');
      v_reviewer_root := "gw_ledger".field(v_evidence_root,'ledger/signer');
      v_recorded_at := "gw_ledger".integer_bigint("gw_ledger".field(v_evidence_root,'ledger/timestamp'));
      v_decision := "gw_ledger".review_decision_text("gw_ledger".field(i_review_root,'review/decision'));
      WITH j_ret AS (  
        INSERT INTO "gw_ledger"."WorkspaceReview" (
          "review_root",
          "workspace_id_root",
          "candidate_root",
          "reviewer_root",
          "decision",
          "recorded_at"
        ) VALUES (
          (i_review_root)::BYTEA,
          (o_candidate ->> 'workspace_id_root')::BYTEA,
          (v_candidate_root)::BYTEA,
          (v_reviewer_root)::BYTEA,
          (v_decision)::TEXT,
          (v_recorded_at)::BIGINT
        ) RETURNING
          "review_root",
          "workspace_id_root",
          "candidate_root",
          "reviewer_root",
          "decision",
          "recorded_at")
      SELECT to_jsonb(j_ret) FROM j_ret INTO o_insert;
      RETURN i_review_root;
    END;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-review/workspace-review-put [421] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_review_put(
  i_candidate_root BYTEA,
  i_reviewer_root BYTEA,
  i_decision TEXT,
  i_recorded_at BIGINT
) RETURNS BYTEA AS $$

  DECLARE
    v_root BYTEA;
  BEGIN
    IF NOT ("gw_ledger".review_decision_valid(i_decision)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_review_decision',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-review-decision'
      ;
    END IF;
    IF NOT (i_recorded_at >= 0) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_review_recorded_at',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-review-recorded-at'
      ;
    END IF;
    v_root := "gw_ledger".workspace_review_value(i_candidate_root,i_reviewer_root,i_decision,i_recorded_at);
    RETURN "gw_ledger".workspace_review_import(v_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-review/review-scope [439] 
CREATE OR REPLACE FUNCTION "gw_ledger".review_scope(
  i_workspace_id_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN "gw_ledger".personal_scope(i_workspace_id_root);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-review/proposal-published [446] 
CREATE OR REPLACE FUNCTION "gw_ledger".proposal_published(
  i_workspace_id_root BYTEA,
  i_candidate_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    o_row := "gw_ledger".scoped_ref_row(
      "gw_ledger".review_scope(i_workspace_id_root),
      "gw_ledger".proposal_name(i_candidate_root)
    );
    RETURN o_row IS NOT NULL AND ((o_row ->> 'root')::BYTEA = i_candidate_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-review/review-transition-error [458] 
CREATE OR REPLACE FUNCTION "gw_ledger".review_transition_error(
  i_workspace_id_root BYTEA,
  i_candidate_root BYTEA,
  i_reviewer_root BYTEA,
  i_expected_review_root BYTEA,
  i_decision TEXT,
  i_recorded_at BIGINT
) RETURNS TEXT AS $$

  DECLARE
    o_candidate JSONB;
    o_expected JSONB;
  BEGIN
    o_candidate := "gw_ledger".workspace_commit_row(i_candidate_root);
    o_expected := CASE WHEN i_expected_review_root IS NULL THEN null
    ELSE "gw_ledger".workspace_review_row(i_expected_review_root)
    END;
    IF "gw_ledger".cell_by_hash(i_workspace_id_root) is null  THEN
      RETURN 'workspace/invalid-workspace-id';
    ELSIF o_candidate is null  THEN
      RETURN 'workspace/review-candidate-not-found';
    ELSIF NOT "gw_ledger".workspace_commit_valid(i_candidate_root) THEN
      RETURN 'workspace/invalid-review-candidate';
    ELSIF NOT (i_workspace_id_root = (o_candidate ->> 'workspace_id_root')::BYTEA) THEN
      RETURN 'workspace/review-candidate-workspace-mismatch';
    ELSIF NOT "gw_ledger".proposal_published(i_workspace_id_root,i_candidate_root) THEN
      RETURN 'workspace/review-proposal-not-published';
    ELSIF NOT "gw_ledger".review_decision_valid(i_decision) THEN
      RETURN 'workspace/invalid-review-decision';
    ELSIF i_recorded_at < 0 THEN
      RETURN 'workspace/invalid-review-recorded-at';
    ELSIF NOT "gw_ledger".ref_part_valid("gw_ledger".review_scope(i_workspace_id_root)) THEN
      RETURN 'workspace/invalid-review-ref-scope';
    ELSIF NOT "gw_ledger".ref_part_valid(
      "gw_ledger".review_ref_name(i_candidate_root,i_reviewer_root)
    ) THEN
      RETURN 'workspace/invalid-review-ref-name';
    ELSIF i_expected_review_root IS NOT NULL AND o_expected IS NULL THEN
      RETURN 'workspace/expected-review-not-found';
    ELSIF i_expected_review_root IS NOT NULL AND NOT "gw_ledger".workspace_review_valid(i_expected_review_root) THEN
      RETURN 'workspace/invalid-expected-review';
    ELSIF i_expected_review_root IS NOT NULL AND NOT (i_workspace_id_root = (o_expected ->> 'workspace_id_root')::BYTEA) THEN
      RETURN 'workspace/expected-review-workspace-mismatch';
    ELSIF i_expected_review_root IS NOT NULL AND NOT (i_candidate_root = (o_expected ->> 'candidate_root')::BYTEA) THEN
      RETURN 'workspace/expected-review-candidate-mismatch';
    ELSIF i_expected_review_root IS NOT NULL AND NOT (i_reviewer_root = (o_expected ->> 'reviewer_root')::BYTEA) THEN
      RETURN 'workspace/expected-review-reviewer-mismatch';
    ELSE
      RETURN null;
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-review/workspace-review-intent-value [539] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_review_intent_value(
  i_workspace_id_root BYTEA,
  i_candidate_root BYTEA,
  i_reviewer_root BYTEA,
  i_expected_review_root BYTEA,
  i_desired_review_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_authority BYTEA;
    v_desired BYTEA;
    v_empty_map BYTEA;
    v_expected BYTEA;
    v_extensions BYTEA;
    v_name TEXT;
    v_name_record BYTEA;
    v_policy BYTEA;
    v_record BYTEA;
    v_scope TEXT;
    v_scope_record BYTEA;
    v_version BYTEA;
    v_workspace BYTEA;
  BEGIN
    v_scope := "gw_ledger".review_scope(i_workspace_id_root);
    v_name := "gw_ledger".review_ref_name(i_candidate_root,i_reviewer_root);
    v_empty_map := "gw_ledger".put_map(jsonb_build_array());
    v_record := "gw_ledger".record_start('workspace/ref-update-intent');
    v_version := "gw_ledger".record_assoc(v_record,'record/version',"gw_ledger".put_integer_number(1));
    v_extensions := "gw_ledger".record_assoc(v_version,'record/extensions',v_empty_map);
    v_workspace := "gw_ledger".record_assoc(v_extensions,'workspace/id',i_workspace_id_root);
    v_scope_record := "gw_ledger".record_assoc(v_workspace,'ref/scope',"gw_ledger".put_string(v_scope));
    v_name_record := "gw_ledger".record_assoc(v_scope_record,'ref/name',"gw_ledger".put_string(v_name));
    v_expected := "gw_ledger".record_assoc(
      v_name_record,
      'ref/expected-root',
      "gw_ledger".optional_root(i_expected_review_root)
    );
    v_desired := "gw_ledger".record_assoc(v_expected,'ref/desired-root',i_desired_review_root);
    v_authority := "gw_ledger".record_assoc(v_desired,'ref/authorization-root',i_reviewer_root);
    v_policy := "gw_ledger".record_assoc(
      v_authority,
      'ref/policy',
      "gw_ledger".put_keyword('review-decision-v1')
    );
    RETURN "gw_ledger".record_assoc(v_policy,'ref/metadata',v_empty_map);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-review/workspace-review-signing-request [588] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_review_signing_request(
  i_network TEXT,
  i_public_key BYTEA,
  i_workspace_id_root BYTEA,
  i_candidate_root BYTEA,
  i_expected_review_root BYTEA,
  i_decision TEXT,
  i_recorded_at BIGINT,
  i_cost_limit BIGINT
) RETURNS JSONB AS $$

  DECLARE
    o_head JSONB;
    v_account_root BYTEA;
    v_address_root BYTEA;
    v_controller_root BYTEA;
    v_expected_controller BYTEA;
    v_intent_root BYTEA;
    v_op_root BYTEA;
    v_payload BYTEA;
    v_review_root BYTEA;
    v_runtime_root BYTEA;
    v_sequence BIGINT;
    v_state_root BYTEA;
    v_transition_error TEXT;
  BEGIN
    o_head := "gw_ledger".head_get(i_network);
    IF NOT (o_head IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/network_missing','data',null))::TEXT,
        MESSAGE = 'ledger/network-missing'
      ;
    END IF;
    IF NOT (i_cost_limit >= 1) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_cost_limit','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-cost-limit'
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
    v_transition_error := "gw_ledger".review_transition_error(
      i_workspace_id_root,
      i_candidate_root,
      v_address_root,
      i_expected_review_root,
      i_decision,
      i_recorded_at
    );
    IF NOT (v_transition_error IS NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_workspace_review_update',
          'data',
          v_transition_error
        ))::TEXT,
        MESSAGE = 'ledger/invalid-workspace-review-update'
      ;
    END IF;
    v_review_root := "gw_ledger".workspace_review_put(i_candidate_root,v_address_root,i_decision,i_recorded_at);
    IF NOT (i_expected_review_root IS NULL OR NOT (i_expected_review_root = v_review_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/noop_workspace_review_update',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/noop-workspace-review-update'
      ;
    END IF;
    v_intent_root := "gw_ledger".workspace_review_intent_value(
      i_workspace_id_root,
      i_candidate_root,
      v_address_root,
      i_expected_review_root,
      v_review_root
    );
    v_op_root := "gw_ledger".constant(v_intent_root);
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
      'workspace_id_root',
      encode(i_workspace_id_root,'hex'),
      'candidate_root',
      encode(i_candidate_root,'hex'),
      'scope',
      "gw_ledger".review_scope(i_workspace_id_root),
      'name',
      "gw_ledger".review_ref_name(i_candidate_root,v_address_root),
      'expected_review_root',
      "gw_ledger".root_hex(i_expected_review_root),
      'review_root',
      encode(v_review_root,'hex'),
      'decision',
      i_decision,
      'recorded_at',
      i_recorded_at,
      'policy',
      'review-decision-v1',
      'intent_root',
      encode(v_intent_root,'hex'),
      'operation_root',
      encode(v_op_root,'hex'),
      'signing_payload',
      encode(v_payload,'hex')
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-review/workspace-review-submit [661] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_review_submit(
  i_network TEXT,
  i_public_key BYTEA,
  i_sequence BIGINT,
  i_workspace_id_root BYTEA,
  i_candidate_root BYTEA,
  i_expected_review_root BYTEA,
  i_decision TEXT,
  i_recorded_at BIGINT,
  i_cost_limit BIGINT,
  i_signature BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_cas JSONB;
    o_head JSONB;
    v_account_root BYTEA;
    v_address_root BYTEA;
    v_cas_status TEXT;
    v_controller_root BYTEA;
    v_current_sequence BIGINT;
    v_expected_controller BYTEA;
    v_intent_root BYTEA;
    v_name TEXT;
    v_op_root BYTEA;
    v_previous_height BIGINT;
    v_previous_state BYTEA;
    v_review_root BYTEA;
    v_runtime_root BYTEA;
    v_scope TEXT;
    v_signing_payload BYTEA;
    v_transition_error TEXT;
  BEGIN
    o_head := "gw_ledger".head_lock(i_network);
    IF NOT (o_head IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/network_missing','data',null))::TEXT,
        MESSAGE = 'ledger/network-missing'
      ;
    END IF;
    IF NOT (i_cost_limit >= 1) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_cost_limit','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-cost-limit'
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
    v_transition_error := "gw_ledger".review_transition_error(
      i_workspace_id_root,
      i_candidate_root,
      v_address_root,
      i_expected_review_root,
      i_decision,
      i_recorded_at
    );
    IF NOT (v_transition_error IS NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_workspace_review_update',
          'data',
          v_transition_error
        ))::TEXT,
        MESSAGE = 'ledger/invalid-workspace-review-update'
      ;
    END IF;
    v_review_root := "gw_ledger".workspace_review_put(i_candidate_root,v_address_root,i_decision,i_recorded_at);
    IF NOT (i_expected_review_root IS NULL OR NOT (i_expected_review_root = v_review_root)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/noop_workspace_review_update',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/noop-workspace-review-update'
      ;
    END IF;
    v_scope := "gw_ledger".review_scope(i_workspace_id_root);
    v_name := "gw_ledger".review_ref_name(i_candidate_root,v_address_root);
    v_intent_root := "gw_ledger".workspace_review_intent_value(
      i_workspace_id_root,
      i_candidate_root,
      v_address_root,
      i_expected_review_root,
      v_review_root
    );
    v_op_root := "gw_ledger".constant(v_intent_root);
    v_runtime_root := "gw_ledger".put_integer('1');
    v_signing_payload := "gw_ledger".transaction_signing_payload(
      i_network,
      v_address_root,
      i_sequence,
      v_op_root,
      null,
      i_cost_limit,
      v_runtime_root
    );
    IF NOT ("gw_ledger".signature_verify(i_signature,v_signing_payload,i_public_key)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_workspace_review_signature',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-workspace-review-signature'
      ;
    END IF;
    o_cas := "gw_ledger".scoped_ref_compare_and_set(
      v_scope,
      v_name,
      i_expected_review_root,
      v_review_root,
      v_address_root
    );
    v_cas_status := (o_cas ->> 'status')::TEXT;
    IF NOT (v_cas_status = 'ok') THEN
      RETURN o_cas || jsonb_build_object(
        'address',
        encode(v_address_root,'hex'),
        'candidate_root',
        encode(i_candidate_root,'hex'),
        'review_root',
        encode(v_review_root,'hex'),
        'decision',
        i_decision,
        'recorded_at',
        i_recorded_at,
        'policy',
        'review-decision-v1',
        'intent_root',
        encode(v_intent_root,'hex'),
        'sequence',
        i_sequence
      );
    END IF;
    DECLARE
      o_bound JSONB;
      o_receipt JSONB;
      v_block_root BYTEA;
      v_receipt_root BYTEA;
      v_state_root BYTEA;
      v_transaction_root BYTEA;
    BEGIN
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
        i_recorded_at
      );
      o_receipt := "gw_ledger".transaction_receipt_get(v_receipt_root);
      IF NOT (o_receipt IS NOT NULL) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_receipt','data',null))::TEXT,
          MESSAGE = 'ledger/missing-receipt'
        ;
      END IF;
      IF NOT (((o_receipt ->> 'status')::TEXT = 'ok') AND ((o_receipt ->> 'result_root')::BYTEA = v_intent_root)) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object(
            'status',
            'error',
            'tag',
            'ledger/workspace_review_receipt_mismatch',
            'data',
            null
          ))::TEXT,
          MESSAGE = 'ledger/workspace-review-receipt-mismatch'
        ;
      END IF;
      v_state_root := (o_receipt ->> 'state_root')::BYTEA;
      v_block_root := "gw_ledger".block_commit(
        i_network,
        v_previous_height,
        v_previous_state,
        v_previous_height + 1,
        (o_head ->> 'block_root')::BYTEA,
        v_previous_state,
        v_state_root,
        i_recorded_at,
        "gw_ledger".admission_proposer_root(),
        null,
        jsonb_build_array(encode(v_transaction_root,'hex'))
      );
      o_bound := "gw_ledger".block_transaction_bind(v_block_root,0,v_receipt_root);
      RETURN jsonb_build_object(
        'status',
        'ok',
        'address',
        encode(v_address_root,'hex'),
        'sequence',
        i_sequence,
        'workspace_id_root',
        encode(i_workspace_id_root,'hex'),
        'candidate_root',
        encode(i_candidate_root,'hex'),
        'scope',
        v_scope,
        'name',
        v_name,
        'expected_review_root',
        "gw_ledger".root_hex(i_expected_review_root),
        'review_root',
        encode(v_review_root,'hex'),
        'decision',
        i_decision,
        'recorded_at',
        i_recorded_at,
        'policy',
        'review-decision-v1',
        'ref_version',
        (o_cas ->> 'version')::BIGINT,
        'intent_root',
        encode(v_intent_root,'hex'),
        'transaction_root',
        encode(v_transaction_root,'hex'),
        'receipt_root',
        encode(v_receipt_root,'hex'),
        'result_root',
        encode((o_receipt ->> 'result_root')::BYTEA,'hex'),
        'state_root',
        encode(v_state_root,'hex'),
        'block_root',
        encode(v_block_root,'hex')
      );
    END;
  END;

$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pgsodium";

-- gwdb.ledger.workspace-acceptance/WorkspaceMainPolicy [38] 
DROP TABLE IF EXISTS "gw_ledger"."WorkspaceMainPolicy" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."WorkspaceMainPolicy" (
  "policy_root" BYTEA PRIMARY KEY,
  "workspace_id_root" BYTEA NOT NULL,
  "authority_root" BYTEA NOT NULL,
  "reviewer_roots_root" BYTEA NOT NULL,
  "recorded_at" BIGINT NOT NULL
);

-- gwdb.ledger.workspace-acceptance/main-policy-scope [47] 
CREATE OR REPLACE FUNCTION "gw_ledger".main_policy_scope(
  i_workspace_id_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN "gw_ledger".personal_scope(i_workspace_id_root);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-acceptance/main-policy-ref-name [54] 
CREATE OR REPLACE FUNCTION "gw_ledger".main_policy_ref_name() RETURNS TEXT AS $$

  SELECT RETURN 'policy/main';

$$ LANGUAGE 'sql' IMMUTABLE PARALLEL SAFE;

-- gwdb.ledger.workspace-acceptance/main-policy-id [62] 
CREATE OR REPLACE FUNCTION "gw_ledger".main_policy_id(
  i_workspace_id_root BYTEA,
  i_authority_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN 'main-policy/' || "gw_ledger".workspace_id_text(i_workspace_id_root) || '/' || encode(i_authority_root,'hex');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-acceptance/main-policy-extensions-value [72] 
CREATE OR REPLACE FUNCTION "gw_ledger".main_policy_extensions_value(
  i_reviewer_roots_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_empty_map BYTEA;
    v_kind BYTEA;
  BEGIN
    v_empty_map := "gw_ledger".put_map(jsonb_build_array());
    v_kind := "gw_ledger".record_assoc(
      v_empty_map,
      'workspace/policy-kind',
      "gw_ledger".put_keyword('unanimous-reviewers-v1')
    );
    RETURN "gw_ledger".record_assoc(v_kind,'workspace/reviewer-roots',i_reviewer_roots_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-acceptance/workspace-main-policy-value [87] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_main_policy_value(
  i_workspace_id_root BYTEA,
  i_authority_root BYTEA,
  i_reviewer_roots_root BYTEA,
  i_recorded_at BIGINT
) RETURNS BYTEA AS $$

  DECLARE
    v_audience BYTEA;
    v_claim BYTEA;
    v_context BYTEA;
    v_empty_map BYTEA;
    v_empty_vector BYTEA;
    v_evidence_roots BYTEA;
    v_extensions BYTEA;
    v_id BYTEA;
    v_issuer BYTEA;
    v_process_id BYTEA;
    v_process_root BYTEA;
    v_record BYTEA;
    v_revokes BYTEA;
    v_scope BYTEA;
    v_subject_id BYTEA;
    v_subject_root BYTEA;
    v_valid_from BYTEA;
    v_valid_until BYTEA;
    v_version BYTEA;
  BEGIN
    v_empty_map := "gw_ledger".put_map(jsonb_build_array());
    v_empty_vector := "gw_ledger".put_vector(jsonb_build_array());
    v_record := "gw_ledger".record_start('attestation/claim');
    v_version := "gw_ledger".record_assoc(v_record,'record/version',"gw_ledger".put_integer_number(1));
    v_extensions := "gw_ledger".record_assoc(
      v_version,
      'record/extensions',
      "gw_ledger".main_policy_extensions_value(i_reviewer_roots_root)
    );
    v_id := "gw_ledger".record_assoc(v_extensions,'attestation/id',"gw_ledger".put_string(
      "gw_ledger".main_policy_id(i_workspace_id_root,i_authority_root)
    ));
    v_claim := "gw_ledger".record_assoc(
      v_id,
      'attestation/claim',
      "gw_ledger".put_keyword('workspace/main-policy-v1')
    );
    v_subject_id := "gw_ledger".record_assoc(v_claim,'attestation/subject-id',i_workspace_id_root);
    v_subject_root := "gw_ledger".record_assoc(v_subject_id,'attestation/subject-root',i_workspace_id_root);
    v_context := "gw_ledger".record_assoc(
      v_subject_root,
      'attestation/context-root',
      "gw_ledger".put_nil()
    );
    v_evidence_roots := "gw_ledger".record_assoc(v_context,'attestation/evidence-roots',v_empty_vector);
    v_process_id := "gw_ledger".record_assoc(
      v_evidence_roots,
      'attestation/process-run-id',
      "gw_ledger".put_nil()
    );
    v_process_root := "gw_ledger".record_assoc(
      v_process_id,
      'attestation/process-run-root',
      "gw_ledger".put_nil()
    );
    v_issuer := "gw_ledger".record_assoc(
      v_process_root,
      'attestation/issuer-evidence',
      "gw_ledger".review_recorded_evidence_value(i_authority_root,i_recorded_at)
    );
    v_scope := "gw_ledger".record_assoc(
      v_issuer,
      'attestation/scope',
      "gw_ledger".put_keyword('workspace/main')
    );
    v_audience := "gw_ledger".record_assoc(
      v_scope,
      'attestation/audience',
      "gw_ledger".put_keyword('workspace/reviewers')
    );
    v_valid_from := "gw_ledger".record_assoc(
      v_audience,
      'attestation/valid-from',
      "gw_ledger".put_integer_number(i_recorded_at)
    );
    v_valid_until := "gw_ledger".record_assoc(v_valid_from,'attestation/valid-until',"gw_ledger".put_nil());
    v_revokes := "gw_ledger".record_assoc(
      v_valid_until,
      'attestation/revokes-root',
      "gw_ledger".put_nil()
    );
    RETURN "gw_ledger".record_assoc(v_revokes,'attestation/metadata',v_empty_map);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-acceptance/workspace-main-policy-row [162] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_main_policy_row(
  i_policy_root BYTEA
) RETURNS JSONB AS $$
BEGIN
  RETURN WITH j_ret AS (  
    SELECT
      "policy_root",
      "workspace_id_root",
      "authority_root",
      "reviewer_roots_root",
      "recorded_at"
    FROM "gw_ledger"."WorkspaceMainPolicy"
    WHERE "policy_root" = i_policy_root
    LIMIT 1)
  SELECT to_jsonb(j_ret) FROM j_ret;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-acceptance/reviewer-seen-before [169] 
CREATE OR REPLACE FUNCTION "gw_ledger".reviewer_seen_before(
  i_reviewer_roots_root BYTEA,
  i_position INTEGER,
  i_reviewer_root BYTEA
) RETURNS BOOLEAN AS $$
BEGIN
  IF i_position <= 0 THEN
    RETURN false;
  ELSE
    DECLARE
    v_previous INTEGER;
      v_root BYTEA;
  BEGIN
    v_previous := (i_position - 1);
      v_root := "gw_ledger".cell_ref_child(i_reviewer_roots_root,v_previous,'element');
      RETURN (v_root = i_reviewer_root) OR "gw_ledger".reviewer_seen_before(i_reviewer_roots_root,v_previous,i_reviewer_root);
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-acceptance/main-policy-reviewer-error-at [189] 
CREATE OR REPLACE FUNCTION "gw_ledger".main_policy_reviewer_error_at(
  i_reviewer_roots_root BYTEA,
  i_position INTEGER,
  i_count INTEGER
) RETURNS TEXT AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN null;
  ELSE
    DECLARE
    v_reviewer_root BYTEA;
  BEGIN
    v_reviewer_root := "gw_ledger".cell_ref_child(i_reviewer_roots_root,i_position,'element');
      IF "gw_ledger".cell_by_hash(v_reviewer_root) is null  THEN
        RETURN 'workspace/main-policy-reviewer-not-found';
      ELSIF "gw_ledger".reviewer_seen_before(i_reviewer_roots_root,i_position,v_reviewer_root) THEN
        RETURN 'workspace/main-policy-duplicate-reviewer';
      ELSE
        RETURN "gw_ledger".main_policy_reviewer_error_at(i_reviewer_roots_root,i_position + 1,i_count);
      END IF;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-acceptance/main-policy-reviewer-error [215] 
CREATE OR REPLACE FUNCTION "gw_ledger".main_policy_reviewer_error(
  i_reviewer_roots_root BYTEA
) RETURNS TEXT AS $$

  DECLARE
    o_vector JSONB;
  BEGIN
    o_vector := "gw_ledger".cell_by_hash(i_reviewer_roots_root);
    IF o_vector is null  THEN
      RETURN 'workspace/main-policy-reviewers-not-found';
    ELSIF NOT ((o_vector ->> 'type_tag')::SMALLINT = 10) THEN
      RETURN 'workspace/main-policy-reviewers-not-vector';
    ELSE
      DECLARE
      v_count INTEGER;
    BEGIN
      v_count := "gw_ledger".cell_ref_count(i_reviewer_roots_root,'element');
        IF _eq(v_count,0) THEN
          RETURN 'workspace/main-policy-missing-reviewers';
        ELSE
          RETURN "gw_ledger".main_policy_reviewer_error_at(i_reviewer_roots_root,0,v_count);
        END IF;
    END;
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-acceptance/workspace-main-policy-error [239] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_main_policy_error(
  i_policy_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  IF NOT "gw_ledger".record_kind(i_policy_root,'attestation/claim') THEN
    RETURN 'workspace/invalid-main-policy-record';
  ELSIF NOT "gw_ledger".record_version_one(i_policy_root) THEN
    RETURN 'workspace/unsupported-main-policy-version';
  ELSE
    DECLARE
    o_evidence_vector JSONB;
      o_recorded_at JSONB;
      o_workspace JSONB;
      v_audience_root BYTEA;
      v_authority_root BYTEA;
      v_claim_root BYTEA;
      v_context_root BYTEA;
      v_empty_map BYTEA;
      v_evidence_roots_root BYTEA;
      v_extensions_root BYTEA;
      v_id_root BYTEA;
      v_issuer_root BYTEA;
      v_metadata_root BYTEA;
      v_policy_kind_root BYTEA;
      v_process_id_root BYTEA;
      v_process_root BYTEA;
      v_recorded_at_root BYTEA;
      v_reviewer_roots_root BYTEA;
      v_revokes_root BYTEA;
      v_scope_root BYTEA;
      v_subject_id_root BYTEA;
      v_valid_from_root BYTEA;
      v_valid_until_root BYTEA;
      v_workspace_id_root BYTEA;
  BEGIN
    v_id_root := "gw_ledger".field(i_policy_root,'attestation/id');
      v_claim_root := "gw_ledger".field(i_policy_root,'attestation/claim');
      v_subject_id_root := "gw_ledger".field(i_policy_root,'attestation/subject-id');
      v_workspace_id_root := "gw_ledger".field(i_policy_root,'attestation/subject-root');
      v_context_root := "gw_ledger".optional_field(i_policy_root,'attestation/context-root');
      v_evidence_roots_root := "gw_ledger".field(i_policy_root,'attestation/evidence-roots');
      v_process_id_root := "gw_ledger".optional_field(i_policy_root,'attestation/process-run-id');
      v_process_root := "gw_ledger".optional_field(i_policy_root,'attestation/process-run-root');
      v_issuer_root := "gw_ledger".field(i_policy_root,'attestation/issuer-evidence');
      v_authority_root := "gw_ledger".field(v_issuer_root,'ledger/signer');
      v_recorded_at_root := "gw_ledger".field(v_issuer_root,'ledger/timestamp');
      v_scope_root := "gw_ledger".field(i_policy_root,'attestation/scope');
      v_audience_root := "gw_ledger".field(i_policy_root,'attestation/audience');
      v_valid_from_root := "gw_ledger".field(i_policy_root,'attestation/valid-from');
      v_valid_until_root := "gw_ledger".optional_field(i_policy_root,'attestation/valid-until');
      v_revokes_root := "gw_ledger".optional_field(i_policy_root,'attestation/revokes-root');
      v_metadata_root := "gw_ledger".field(i_policy_root,'attestation/metadata');
      v_extensions_root := "gw_ledger".field(i_policy_root,'record/extensions');
      v_reviewer_roots_root := "gw_ledger".field(v_extensions_root,'workspace/reviewer-roots');
      v_policy_kind_root := "gw_ledger".field(v_extensions_root,'workspace/policy-kind');
      v_empty_map := "gw_ledger".put_map(jsonb_build_array());
      o_workspace := "gw_ledger".cell_by_hash(v_workspace_id_root);
      o_evidence_vector := "gw_ledger".cell_by_hash(v_evidence_roots_root);
      o_recorded_at := "gw_ledger".cell_by_hash(v_recorded_at_root);
      IF o_workspace IS NULL OR NOT ((o_workspace ->> 'type_tag')::SMALLINT = 5) THEN
        RETURN 'workspace/invalid-main-policy-workspace-id';
      ELSIF NOT (v_subject_id_root = v_workspace_id_root) THEN
        RETURN 'workspace/main-policy-subject-id-mismatch';
      ELSIF NOT (v_claim_root = "gw_ledger".put_keyword('workspace/main-policy-v1')) THEN
        RETURN 'workspace/unsupported-main-policy-claim';
      ELSIF v_context_root is not null  THEN
        RETURN 'workspace/main-policy-context-not-supported';
      ELSIF o_evidence_vector IS NULL OR NOT ((o_evidence_vector ->> 'type_tag')::SMALLINT = 10) OR NOT ("gw_ledger".cell_ref_count(v_evidence_roots_root,'element') = 0) THEN
        RETURN 'workspace/main-policy-evidence-not-empty';
      ELSIF v_process_id_root is not null  THEN
        RETURN 'workspace/main-policy-process-not-supported';
      ELSIF v_process_root is not null  THEN
        RETURN 'workspace/main-policy-process-not-supported';
      ELSIF NOT "gw_ledger".record_kind(v_issuer_root,'ledger/evidence') THEN
        RETURN 'workspace/invalid-main-policy-evidence';
      ELSIF NOT "gw_ledger".record_version_one(v_issuer_root) THEN
        RETURN 'workspace/unsupported-main-policy-evidence';
      ELSIF "gw_ledger".cell_by_hash(v_authority_root) is null  THEN
        RETURN 'workspace/main-policy-authority-not-found';
      ELSIF o_recorded_at IS NULL OR NOT ((o_recorded_at ->> 'type_tag')::SMALLINT = 2) THEN
        RETURN 'workspace/invalid-main-policy-recorded-at';
      ELSIF NOT (v_scope_root = "gw_ledger".put_keyword('workspace/main')) THEN
        RETURN 'workspace/main-policy-scope-mismatch';
      ELSIF NOT (v_audience_root = "gw_ledger".put_keyword('workspace/reviewers')) THEN
        RETURN 'workspace/main-policy-audience-mismatch';
      ELSIF NOT (v_valid_from_root = v_recorded_at_root) THEN
        RETURN 'workspace/main-policy-valid-from-mismatch';
      ELSIF v_valid_until_root is not null  THEN
        RETURN 'workspace/main-policy-expiry-not-supported';
      ELSIF v_revokes_root is not null  THEN
        RETURN 'workspace/main-policy-revocation-not-supported';
      ELSIF NOT (v_metadata_root = v_empty_map) THEN
        RETURN 'workspace/main-policy-metadata-not-supported';
      ELSIF NOT (v_policy_kind_root = "gw_ledger".put_keyword('unanimous-reviewers-v1')) THEN
        RETURN 'workspace/unsupported-main-policy-kind';
      ELSE
        DECLARE
        v_reconstructed BYTEA;
          v_recorded_at BIGINT;
          v_reviewer_error TEXT;
      BEGIN
        v_reviewer_error := "gw_ledger".main_policy_reviewer_error(v_reviewer_roots_root);
          v_recorded_at := "gw_ledger".integer_bigint(v_recorded_at_root);
          v_reconstructed := "gw_ledger".workspace_main_policy_value(
            v_workspace_id_root,
            v_authority_root,
            v_reviewer_roots_root,
            v_recorded_at
          );
          IF v_reviewer_error is not null  THEN
            RETURN v_reviewer_error;
          ELSIF v_recorded_at < 0 THEN
            RETURN 'workspace/invalid-main-policy-recorded-at';
          ELSIF NOT (v_id_root = "gw_ledger".put_string(
            "gw_ledger".main_policy_id(v_workspace_id_root,v_authority_root)
          )) THEN
            RETURN 'workspace/main-policy-id-not-derived';
          ELSIF NOT (v_issuer_root = "gw_ledger".review_recorded_evidence_value(v_authority_root,v_recorded_at)) THEN
            RETURN 'workspace/noncanonical-main-policy-evidence';
          ELSIF NOT (v_extensions_root = "gw_ledger".main_policy_extensions_value(v_reviewer_roots_root)) THEN
            RETURN 'workspace/noncanonical-main-policy-extensions';
          ELSIF NOT (i_policy_root = v_reconstructed) THEN
            RETURN 'workspace/noncanonical-main-policy';
          ELSE
            RETURN null;
          END IF;
      END;
      END IF;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-acceptance/workspace-main-policy-valid [421] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_main_policy_valid(
  i_policy_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    o_row := "gw_ledger".workspace_main_policy_row(i_policy_root);
    IF o_row is null  THEN
      RETURN false;
    END IF;
    DECLARE
      v_authority_root BYTEA;
      v_recorded_at BIGINT;
      v_reviewer_roots_root BYTEA;
      v_workspace_id_root BYTEA;
    BEGIN
      v_workspace_id_root := (o_row ->> 'workspace_id_root')::BYTEA;
      v_authority_root := (o_row ->> 'authority_root')::BYTEA;
      v_reviewer_roots_root := (o_row ->> 'reviewer_roots_root')::BYTEA;
      v_recorded_at := (o_row ->> 'recorded_at')::BIGINT;
      RETURN "gw_ledger".workspace_main_policy_error(i_policy_root) IS NULL AND (i_policy_root = "gw_ledger".workspace_main_policy_value(
        v_workspace_id_root,
        v_authority_root,
        v_reviewer_roots_root,
        v_recorded_at
      ));
    END;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-acceptance/workspace-main-policy-import [443] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_main_policy_import(
  i_policy_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_existing JSONB;
  BEGIN
    o_existing := "gw_ledger".workspace_main_policy_row(i_policy_root);
    IF o_existing is not null  THEN
      IF NOT ("gw_ledger".workspace_main_policy_valid(i_policy_root)) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object(
              'status',
              'error',
              'tag',
              'ledger/workspace_main_policy_projection_conflict',
              'data',
              null
            ))::TEXT,
          MESSAGE = 'ledger/workspace-main-policy-projection-conflict'
        ;
      END IF;
      RETURN i_policy_root;
    END IF;
    DECLARE
      o_insert JSONB;
      v_authority_root BYTEA;
      v_error TEXT;
      v_extensions_root BYTEA;
      v_issuer_root BYTEA;
      v_recorded_at BIGINT;
      v_reviewer_roots_root BYTEA;
      v_workspace_id_root BYTEA;
    BEGIN
      v_error := "gw_ledger".workspace_main_policy_error(i_policy_root);
      IF NOT (v_error IS NULL) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object(
            'status',
            'error',
            'tag',
            'ledger/invalid_workspace_main_policy',
            'data',
            v_error
          ))::TEXT,
          MESSAGE = 'ledger/invalid-workspace-main-policy'
        ;
      END IF;
      v_workspace_id_root := "gw_ledger".field(i_policy_root,'attestation/subject-root');
      v_issuer_root := "gw_ledger".field(i_policy_root,'attestation/issuer-evidence');
      v_authority_root := "gw_ledger".field(v_issuer_root,'ledger/signer');
      v_recorded_at := "gw_ledger".integer_bigint("gw_ledger".field(v_issuer_root,'ledger/timestamp'));
      v_extensions_root := "gw_ledger".field(i_policy_root,'record/extensions');
      v_reviewer_roots_root := "gw_ledger".field(v_extensions_root,'workspace/reviewer-roots');
      WITH j_ret AS (  
        INSERT INTO "gw_ledger"."WorkspaceMainPolicy" (
          "policy_root",
          "workspace_id_root",
          "authority_root",
          "reviewer_roots_root",
          "recorded_at"
        ) VALUES (
          (i_policy_root)::BYTEA,
          (v_workspace_id_root)::BYTEA,
          (v_authority_root)::BYTEA,
          (v_reviewer_roots_root)::BYTEA,
          (v_recorded_at)::BIGINT
        ) RETURNING
          "policy_root",
          "workspace_id_root",
          "authority_root",
          "reviewer_roots_root",
          "recorded_at")
      SELECT to_jsonb(j_ret) FROM j_ret INTO o_insert;
      RETURN i_policy_root;
    END;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-acceptance/workspace-main-policy-put [480] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_main_policy_put(
  i_workspace_id_root BYTEA,
  i_authority_root BYTEA,
  i_reviewer_roots_root BYTEA,
  i_recorded_at BIGINT
) RETURNS BYTEA AS $$

  DECLARE
    v_reviewer_error TEXT;
    v_root BYTEA;
  BEGIN
    v_reviewer_error := "gw_ledger".main_policy_reviewer_error(i_reviewer_roots_root);
    IF NOT (v_reviewer_error IS NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_main_policy_reviewers',
          'data',
          v_reviewer_error
        ))::TEXT,
        MESSAGE = 'ledger/invalid-main-policy-reviewers'
      ;
    END IF;
    IF NOT (i_recorded_at >= 0) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_main_policy_recorded_at',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-main-policy-recorded-at'
      ;
    END IF;
    v_root := "gw_ledger".workspace_main_policy_value(
      i_workspace_id_root,
      i_authority_root,
      i_reviewer_roots_root,
      i_recorded_at
    );
    RETURN "gw_ledger".workspace_main_policy_import(v_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-acceptance/main-policy-transition-error [500] 
CREATE OR REPLACE FUNCTION "gw_ledger".main_policy_transition_error(
  i_workspace_id_root BYTEA,
  i_reviewer_roots_root BYTEA,
  i_recorded_at BIGINT
) RETURNS TEXT AS $$

  DECLARE
    o_workspace JSONB;
    v_reviewer_error TEXT;
  BEGIN
    o_workspace := "gw_ledger".cell_by_hash(i_workspace_id_root);
    v_reviewer_error := "gw_ledger".main_policy_reviewer_error(i_reviewer_roots_root);
    IF o_workspace IS NULL OR NOT ((o_workspace ->> 'type_tag')::SMALLINT = 5) THEN
      RETURN 'workspace/invalid-workspace-id';
    ELSIF v_reviewer_error is not null  THEN
      RETURN v_reviewer_error;
    ELSIF i_recorded_at < 0 THEN
      RETURN 'workspace/invalid-main-policy-recorded-at';
    ELSIF NOT "gw_ledger".ref_part_valid("gw_ledger".main_policy_scope(i_workspace_id_root)) THEN
      RETURN 'workspace/invalid-main-policy-scope';
    ELSIF NOT "gw_ledger".ref_part_valid("gw_ledger".main_policy_ref_name()) THEN
      RETURN 'workspace/invalid-main-policy-ref-name';
    ELSE
      RETURN null;
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-acceptance/workspace-main-policy-signing-request [533] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_main_policy_signing_request(
  i_network TEXT,
  i_public_key BYTEA,
  i_workspace_id_root BYTEA,
  i_reviewer_roots_root BYTEA,
  i_recorded_at BIGINT,
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
    v_policy_root BYTEA;
    v_runtime_root BYTEA;
    v_sequence BIGINT;
    v_state_root BYTEA;
    v_transition_error TEXT;
  BEGIN
    o_head := "gw_ledger".head_get(i_network);
    IF NOT (o_head IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/network_missing','data',null))::TEXT,
        MESSAGE = 'ledger/network-missing'
      ;
    END IF;
    IF NOT (i_cost_limit >= 1) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_cost_limit','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-cost-limit'
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
    v_transition_error := "gw_ledger".main_policy_transition_error(i_workspace_id_root,i_reviewer_roots_root,i_recorded_at);
    IF NOT (v_transition_error IS NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_workspace_main_policy',
          'data',
          v_transition_error
        ))::TEXT,
        MESSAGE = 'ledger/invalid-workspace-main-policy'
      ;
    END IF;
    v_policy_root := "gw_ledger".workspace_main_policy_put(
      i_workspace_id_root,
      v_address_root,
      i_reviewer_roots_root,
      i_recorded_at
    );
    v_op_root := "gw_ledger".constant(v_policy_root);
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
      'workspace_id_root',
      encode(i_workspace_id_root,'hex'),
      'scope',
      "gw_ledger".main_policy_scope(i_workspace_id_root),
      'name',
      "gw_ledger".main_policy_ref_name(),
      'expected_root',
      null,
      'reviewer_roots_root',
      encode(i_reviewer_roots_root,'hex'),
      'recorded_at',
      i_recorded_at,
      'policy',
      'unanimous-reviewers-v1',
      'policy_root',
      encode(v_policy_root,'hex'),
      'operation_root',
      encode(v_op_root,'hex'),
      'signing_payload',
      encode(v_payload,'hex')
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-acceptance/workspace-main-policy-submit [593] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_main_policy_submit(
  i_network TEXT,
  i_public_key BYTEA,
  i_sequence BIGINT,
  i_workspace_id_root BYTEA,
  i_reviewer_roots_root BYTEA,
  i_recorded_at BIGINT,
  i_cost_limit BIGINT,
  i_signature BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_cas JSONB;
    o_head JSONB;
    v_account_root BYTEA;
    v_address_root BYTEA;
    v_cas_status TEXT;
    v_controller_root BYTEA;
    v_current_sequence BIGINT;
    v_expected_controller BYTEA;
    v_name TEXT;
    v_op_root BYTEA;
    v_policy_root BYTEA;
    v_previous_height BIGINT;
    v_previous_state BYTEA;
    v_runtime_root BYTEA;
    v_scope TEXT;
    v_signing_payload BYTEA;
    v_transition_error TEXT;
  BEGIN
    o_head := "gw_ledger".head_lock(i_network);
    IF NOT (o_head IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/network_missing','data',null))::TEXT,
        MESSAGE = 'ledger/network-missing'
      ;
    END IF;
    IF NOT (i_cost_limit >= 1) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_cost_limit','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-cost-limit'
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
    v_transition_error := "gw_ledger".main_policy_transition_error(i_workspace_id_root,i_reviewer_roots_root,i_recorded_at);
    IF NOT (v_transition_error IS NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_workspace_main_policy',
          'data',
          v_transition_error
        ))::TEXT,
        MESSAGE = 'ledger/invalid-workspace-main-policy'
      ;
    END IF;
    v_policy_root := "gw_ledger".workspace_main_policy_put(
      i_workspace_id_root,
      v_address_root,
      i_reviewer_roots_root,
      i_recorded_at
    );
    v_op_root := "gw_ledger".constant(v_policy_root);
    v_runtime_root := "gw_ledger".put_integer('1');
    v_signing_payload := "gw_ledger".transaction_signing_payload(
      i_network,
      v_address_root,
      i_sequence,
      v_op_root,
      null,
      i_cost_limit,
      v_runtime_root
    );
    IF NOT ("gw_ledger".signature_verify(i_signature,v_signing_payload,i_public_key)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_workspace_main_policy_signature',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-workspace-main-policy-signature'
      ;
    END IF;
    v_scope := "gw_ledger".main_policy_scope(i_workspace_id_root);
    v_name := "gw_ledger".main_policy_ref_name();
    o_cas := "gw_ledger".scoped_ref_compare_and_set(v_scope,v_name,null,v_policy_root,v_address_root);
    v_cas_status := (o_cas ->> 'status')::TEXT;
    IF NOT (v_cas_status = 'ok') THEN
      RETURN o_cas || jsonb_build_object(
        'address',
        encode(v_address_root,'hex'),
        'reviewer_roots_root',
        encode(i_reviewer_roots_root,'hex'),
        'recorded_at',
        i_recorded_at,
        'policy',
        'unanimous-reviewers-v1',
        'policy_root',
        encode(v_policy_root,'hex'),
        'sequence',
        i_sequence
      );
    END IF;
    DECLARE
      o_bound JSONB;
      o_receipt JSONB;
      v_block_root BYTEA;
      v_receipt_root BYTEA;
      v_state_root BYTEA;
      v_transaction_root BYTEA;
    BEGIN
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
        i_recorded_at
      );
      o_receipt := "gw_ledger".transaction_receipt_get(v_receipt_root);
      IF NOT (o_receipt IS NOT NULL) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_receipt','data',null))::TEXT,
          MESSAGE = 'ledger/missing-receipt'
        ;
      END IF;
      IF NOT (((o_receipt ->> 'status')::TEXT = 'ok') AND ((o_receipt ->> 'result_root')::BYTEA = v_policy_root)) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object(
            'status',
            'error',
            'tag',
            'ledger/workspace_main_policy_receipt_mismatch',
            'data',
            null
          ))::TEXT,
          MESSAGE = 'ledger/workspace-main-policy-receipt-mismatch'
        ;
      END IF;
      v_state_root := (o_receipt ->> 'state_root')::BYTEA;
      v_block_root := "gw_ledger".block_commit(
        i_network,
        v_previous_height,
        v_previous_state,
        v_previous_height + 1,
        (o_head ->> 'block_root')::BYTEA,
        v_previous_state,
        v_state_root,
        i_recorded_at,
        "gw_ledger".admission_proposer_root(),
        null,
        jsonb_build_array(encode(v_transaction_root,'hex'))
      );
      o_bound := "gw_ledger".block_transaction_bind(v_block_root,0,v_receipt_root);
      RETURN jsonb_build_object(
        'status',
        'ok',
        'address',
        encode(v_address_root,'hex'),
        'sequence',
        i_sequence,
        'workspace_id_root',
        encode(i_workspace_id_root,'hex'),
        'scope',
        v_scope,
        'name',
        v_name,
        'expected_root',
        null,
        'reviewer_roots_root',
        encode(i_reviewer_roots_root,'hex'),
        'recorded_at',
        i_recorded_at,
        'policy',
        'unanimous-reviewers-v1',
        'policy_root',
        encode(v_policy_root,'hex'),
        'ref_version',
        (o_cas ->> 'version')::BIGINT,
        'transaction_root',
        encode(v_transaction_root,'hex'),
        'receipt_root',
        encode(v_receipt_root,'hex'),
        'result_root',
        encode((o_receipt ->> 'result_root')::BYTEA,'hex'),
        'state_root',
        encode(v_state_root,'hex'),
        'block_root',
        encode(v_block_root,'hex')
      );
    END;
  END;

$$ LANGUAGE 'plpgsql';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pgsodium";

-- gwdb.ledger.workspace-main/WorkspaceMainAcceptance [42] 
DROP TABLE IF EXISTS "gw_ledger"."WorkspaceMainAcceptance" CASCADE;
CREATE TABLE IF NOT EXISTS "gw_ledger"."WorkspaceMainAcceptance" (
  "acceptance_root" BYTEA PRIMARY KEY,
  "workspace_id_root" BYTEA NOT NULL,
  "authority_root" BYTEA NOT NULL,
  "expected_root" BYTEA,
  "candidate_root" BYTEA NOT NULL,
  "policy_root" BYTEA NOT NULL,
  "review_roots_root" BYTEA NOT NULL,
  "recorded_at" BIGINT NOT NULL
);

-- gwdb.ledger.workspace-main/main-scope [54] 
CREATE OR REPLACE FUNCTION "gw_ledger".main_scope(
  i_workspace_id_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN "gw_ledger".personal_scope(i_workspace_id_root);
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-main/main-ref-name [61] 
CREATE OR REPLACE FUNCTION "gw_ledger".main_ref_name() RETURNS TEXT AS $$

  SELECT RETURN 'main';

$$ LANGUAGE 'sql' IMMUTABLE PARALLEL SAFE;

-- gwdb.ledger.workspace-main/main-acceptance-id [69] 
CREATE OR REPLACE FUNCTION "gw_ledger".main_acceptance_id(
  i_workspace_id_root BYTEA,
  i_candidate_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  RETURN 'main-acceptance/' || "gw_ledger".workspace_id_text(i_workspace_id_root) || '/' || encode(i_candidate_root,'hex');
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-main/main-acceptance-extensions-value [79] 
CREATE OR REPLACE FUNCTION "gw_ledger".main_acceptance_extensions_value(
  i_workspace_id_root BYTEA,
  i_expected_root BYTEA,
  i_candidate_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    v_desired BYTEA;
    v_empty_map BYTEA;
    v_expected BYTEA;
    v_workspace BYTEA;
  BEGIN
    v_empty_map := "gw_ledger".put_map(jsonb_build_array());
    v_workspace := "gw_ledger".record_assoc(v_empty_map,'workspace/id',i_workspace_id_root);
    v_expected := "gw_ledger".record_assoc(
      v_workspace,
      'ref/expected-root',
      "gw_ledger".optional_root(i_expected_root)
    );
    v_desired := "gw_ledger".record_assoc(v_expected,'ref/desired-root',i_candidate_root);
    RETURN "gw_ledger".record_assoc(
      v_desired,
      'ref/policy',
      "gw_ledger".put_keyword('main-acceptance-v1')
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-main/workspace-main-acceptance-value [102] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_main_acceptance_value(
  i_workspace_id_root BYTEA,
  i_authority_root BYTEA,
  i_expected_root BYTEA,
  i_candidate_root BYTEA,
  i_policy_root BYTEA,
  i_review_roots_root BYTEA,
  i_recorded_at BIGINT
) RETURNS BYTEA AS $$

  DECLARE
    v_audience BYTEA;
    v_claim BYTEA;
    v_context BYTEA;
    v_empty_map BYTEA;
    v_evidence_roots BYTEA;
    v_extensions BYTEA;
    v_id BYTEA;
    v_issuer BYTEA;
    v_process_id BYTEA;
    v_process_root BYTEA;
    v_record BYTEA;
    v_revokes BYTEA;
    v_scope BYTEA;
    v_subject_id BYTEA;
    v_subject_root BYTEA;
    v_valid_from BYTEA;
    v_valid_until BYTEA;
    v_version BYTEA;
  BEGIN
    v_empty_map := "gw_ledger".put_map(jsonb_build_array());
    v_record := "gw_ledger".record_start('attestation/claim');
    v_version := "gw_ledger".record_assoc(v_record,'record/version',"gw_ledger".put_integer_number(1));
    v_extensions := "gw_ledger".record_assoc(
      v_version,
      'record/extensions',
      "gw_ledger".main_acceptance_extensions_value(i_workspace_id_root,i_expected_root,i_candidate_root)
    );
    v_id := "gw_ledger".record_assoc(v_extensions,'attestation/id',"gw_ledger".put_string(
      "gw_ledger".main_acceptance_id(i_workspace_id_root,i_candidate_root)
    ));
    v_claim := "gw_ledger".record_assoc(
      v_id,
      'attestation/claim',
      "gw_ledger".put_keyword('workspace/main-accepted-v1')
    );
    v_subject_id := "gw_ledger".record_assoc(
      v_claim,
      'attestation/subject-id',
      "gw_ledger".put_string("gw_ledger".proposal_name(i_candidate_root))
    );
    v_subject_root := "gw_ledger".record_assoc(v_subject_id,'attestation/subject-root',i_candidate_root);
    v_context := "gw_ledger".record_assoc(v_subject_root,'attestation/context-root',i_policy_root);
    v_evidence_roots := "gw_ledger".record_assoc(v_context,'attestation/evidence-roots',i_review_roots_root);
    v_process_id := "gw_ledger".record_assoc(
      v_evidence_roots,
      'attestation/process-run-id',
      "gw_ledger".put_nil()
    );
    v_process_root := "gw_ledger".record_assoc(
      v_process_id,
      'attestation/process-run-root',
      "gw_ledger".put_nil()
    );
    v_issuer := "gw_ledger".record_assoc(
      v_process_root,
      'attestation/issuer-evidence',
      "gw_ledger".review_recorded_evidence_value(i_authority_root,i_recorded_at)
    );
    v_scope := "gw_ledger".record_assoc(
      v_issuer,
      'attestation/scope',
      "gw_ledger".put_keyword('workspace/main')
    );
    v_audience := "gw_ledger".record_assoc(
      v_scope,
      'attestation/audience',
      "gw_ledger".put_keyword('workspace/members')
    );
    v_valid_from := "gw_ledger".record_assoc(
      v_audience,
      'attestation/valid-from',
      "gw_ledger".put_integer_number(i_recorded_at)
    );
    v_valid_until := "gw_ledger".record_assoc(v_valid_from,'attestation/valid-until',"gw_ledger".put_nil());
    v_revokes := "gw_ledger".record_assoc(
      v_valid_until,
      'attestation/revokes-root',
      "gw_ledger".put_nil()
    );
    RETURN "gw_ledger".record_assoc(v_revokes,'attestation/metadata',v_empty_map);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-main/workspace-main-acceptance-row [182] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_main_acceptance_row(
  i_acceptance_root BYTEA
) RETURNS JSONB AS $$
BEGIN
  RETURN WITH j_ret AS (  
    SELECT
      "acceptance_root",
      "workspace_id_root",
      "authority_root",
      "expected_root",
      "candidate_root",
      "policy_root",
      "review_roots_root",
      "recorded_at"
    FROM "gw_ledger"."WorkspaceMainAcceptance"
    WHERE "acceptance_root" = i_acceptance_root
    LIMIT 1)
  SELECT to_jsonb(j_ret) FROM j_ret;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-main/review-root-seen-before [189] 
CREATE OR REPLACE FUNCTION "gw_ledger".review_root_seen_before(
  i_review_roots_root BYTEA,
  i_position INTEGER,
  i_review_root BYTEA
) RETURNS BOOLEAN AS $$
BEGIN
  IF i_position <= 0 THEN
    RETURN false;
  ELSE
    DECLARE
    v_previous INTEGER;
      v_root BYTEA;
  BEGIN
    v_previous := (i_position - 1);
      v_root := "gw_ledger".cell_ref_child(i_review_roots_root,v_previous,'element');
      RETURN (v_root = i_review_root) OR "gw_ledger".review_root_seen_before(i_review_roots_root,v_previous,i_review_root);
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-main/acceptance-review-vector-error-at [208] 
CREATE OR REPLACE FUNCTION "gw_ledger".acceptance_review_vector_error_at(
  i_review_roots_root BYTEA,
  i_position INTEGER,
  i_count INTEGER
) RETURNS TEXT AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN null;
  ELSE
    DECLARE
    o_review_cell JSONB;
      v_review_root BYTEA;
  BEGIN
    v_review_root := "gw_ledger".cell_ref_child(i_review_roots_root,i_position,'element');
      o_review_cell := "gw_ledger".cell_by_hash(v_review_root);
      IF o_review_cell is null  THEN
        RETURN 'workspace/main-acceptance-review-not-found';
      ELSIF (o_review_cell ->> 'type_tag')::SMALLINT = 0 THEN
        RETURN 'workspace/main-acceptance-nil-review-root';
      ELSIF "gw_ledger".review_root_seen_before(i_review_roots_root,i_position,v_review_root) THEN
        RETURN 'workspace/main-acceptance-duplicate-review-root';
      ELSE
        RETURN "gw_ledger".acceptance_review_vector_error_at(i_review_roots_root,i_position + 1,i_count);
      END IF;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-main/acceptance-review-vector-error [237] 
CREATE OR REPLACE FUNCTION "gw_ledger".acceptance_review_vector_error(
  i_review_roots_root BYTEA
) RETURNS TEXT AS $$

  DECLARE
    o_vector JSONB;
  BEGIN
    o_vector := "gw_ledger".cell_by_hash(i_review_roots_root);
    IF o_vector is null  THEN
      RETURN 'workspace/main-acceptance-reviews-not-found';
    ELSIF NOT ((o_vector ->> 'type_tag')::SMALLINT = 10) THEN
      RETURN 'workspace/main-acceptance-reviews-not-vector';
    ELSE
      DECLARE
      v_count INTEGER;
    BEGIN
      v_count := "gw_ledger".cell_ref_count(i_review_roots_root,'element');
        IF _eq(v_count,0) THEN
          RETURN 'workspace/main-acceptance-missing-reviews';
        ELSE
          RETURN "gw_ledger".acceptance_review_vector_error_at(i_review_roots_root,0,v_count);
        END IF;
    END;
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-main/workspace-main-acceptance-error [260] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_main_acceptance_error(
  i_acceptance_root BYTEA
) RETURNS TEXT AS $$
BEGIN
  IF NOT "gw_ledger".record_kind(i_acceptance_root,'attestation/claim') THEN
    RETURN 'workspace/invalid-main-acceptance-record';
  ELSIF NOT "gw_ledger".record_version_one(i_acceptance_root) THEN
    RETURN 'workspace/unsupported-main-acceptance-version';
  ELSE
    DECLARE
    o_candidate JSONB;
      o_policy JSONB;
      o_recorded_at JSONB;
      o_workspace JSONB;
      v_audience_root BYTEA;
      v_authority_root BYTEA;
      v_candidate_root BYTEA;
      v_claim_root BYTEA;
      v_desired_root BYTEA;
      v_empty_map BYTEA;
      v_expected_root BYTEA;
      v_extensions_root BYTEA;
      v_id_root BYTEA;
      v_issuer_root BYTEA;
      v_metadata_root BYTEA;
      v_policy_root BYTEA;
      v_process_id_root BYTEA;
      v_process_root BYTEA;
      v_recorded_at_root BYTEA;
      v_ref_policy_root BYTEA;
      v_review_roots_root BYTEA;
      v_revokes_root BYTEA;
      v_scope_root BYTEA;
      v_subject_id_root BYTEA;
      v_valid_from_root BYTEA;
      v_valid_until_root BYTEA;
      v_workspace_id_root BYTEA;
  BEGIN
    v_id_root := "gw_ledger".field(i_acceptance_root,'attestation/id');
      v_claim_root := "gw_ledger".field(i_acceptance_root,'attestation/claim');
      v_subject_id_root := "gw_ledger".field(i_acceptance_root,'attestation/subject-id');
      v_candidate_root := "gw_ledger".field(i_acceptance_root,'attestation/subject-root');
      v_policy_root := "gw_ledger".optional_field(i_acceptance_root,'attestation/context-root');
      v_review_roots_root := "gw_ledger".field(i_acceptance_root,'attestation/evidence-roots');
      v_process_id_root := "gw_ledger".optional_field(i_acceptance_root,'attestation/process-run-id');
      v_process_root := "gw_ledger".optional_field(i_acceptance_root,'attestation/process-run-root');
      v_issuer_root := "gw_ledger".field(i_acceptance_root,'attestation/issuer-evidence');
      v_authority_root := "gw_ledger".field(v_issuer_root,'ledger/signer');
      v_recorded_at_root := "gw_ledger".field(v_issuer_root,'ledger/timestamp');
      v_scope_root := "gw_ledger".field(i_acceptance_root,'attestation/scope');
      v_audience_root := "gw_ledger".field(i_acceptance_root,'attestation/audience');
      v_valid_from_root := "gw_ledger".field(i_acceptance_root,'attestation/valid-from');
      v_valid_until_root := "gw_ledger".optional_field(i_acceptance_root,'attestation/valid-until');
      v_revokes_root := "gw_ledger".optional_field(i_acceptance_root,'attestation/revokes-root');
      v_metadata_root := "gw_ledger".field(i_acceptance_root,'attestation/metadata');
      v_extensions_root := "gw_ledger".field(i_acceptance_root,'record/extensions');
      v_workspace_id_root := "gw_ledger".field(v_extensions_root,'workspace/id');
      v_expected_root := "gw_ledger".optional_field(v_extensions_root,'ref/expected-root');
      v_desired_root := "gw_ledger".field(v_extensions_root,'ref/desired-root');
      v_ref_policy_root := "gw_ledger".field(v_extensions_root,'ref/policy');
      v_empty_map := "gw_ledger".put_map(jsonb_build_array());
      o_workspace := "gw_ledger".cell_by_hash(v_workspace_id_root);
      o_candidate := "gw_ledger".workspace_commit_row(v_candidate_root);
      o_policy := "gw_ledger".workspace_main_policy_row(v_policy_root);
      o_recorded_at := "gw_ledger".cell_by_hash(v_recorded_at_root);
      IF o_workspace IS NULL OR NOT ((o_workspace ->> 'type_tag')::SMALLINT = 5) THEN
        RETURN 'workspace/invalid-main-acceptance-workspace-id';
      ELSIF o_candidate is null  THEN
        RETURN 'workspace/main-candidate-not-found';
      ELSIF NOT "gw_ledger".workspace_commit_valid(v_candidate_root) THEN
        RETURN 'workspace/invalid-main-candidate';
      ELSIF o_policy is null  THEN
        RETURN 'workspace/main-policy-not-found';
      ELSIF NOT "gw_ledger".workspace_main_policy_valid(v_policy_root) THEN
        RETURN 'workspace/invalid-main-policy';
      ELSIF NOT (v_desired_root = v_candidate_root) THEN
        RETURN 'workspace/main-acceptance-desired-root-mismatch';
      ELSIF NOT (v_ref_policy_root = "gw_ledger".put_keyword('main-acceptance-v1')) THEN
        RETURN 'workspace/unsupported-main-acceptance-policy';
      ELSIF v_expected_root = v_candidate_root THEN
        RETURN 'workspace/noop-main-acceptance';
      ELSIF v_process_id_root is not null  THEN
        RETURN 'workspace/main-acceptance-process-not-supported';
      ELSIF v_process_root is not null  THEN
        RETURN 'workspace/main-acceptance-process-not-supported';
      ELSIF NOT "gw_ledger".record_kind(v_issuer_root,'ledger/evidence') THEN
        RETURN 'workspace/invalid-main-acceptance-evidence';
      ELSIF NOT "gw_ledger".record_version_one(v_issuer_root) THEN
        RETURN 'workspace/unsupported-main-acceptance-evidence';
      ELSIF "gw_ledger".cell_by_hash(v_authority_root) is null  THEN
        RETURN 'workspace/main-acceptance-authority-not-found';
      ELSIF o_recorded_at IS NULL OR NOT ((o_recorded_at ->> 'type_tag')::SMALLINT = 2) THEN
        RETURN 'workspace/invalid-main-acceptance-recorded-at';
      ELSIF "gw_ledger".optional_field(v_issuer_root,'ledger/transaction-root') is not null  THEN
        RETURN 'workspace/main-acceptance-transaction-evidence-not-supported';
      ELSIF "gw_ledger".optional_field(v_issuer_root,'ledger/previous-head-root') is not null  THEN
        RETURN 'workspace/main-acceptance-head-evidence-not-supported';
      ELSIF "gw_ledger".optional_field(v_issuer_root,'ledger/contract-root') is not null  THEN
        RETURN 'workspace/main-acceptance-contract-evidence-not-supported';
      ELSIF "gw_ledger".optional_field(v_issuer_root,'ledger/template-root') is not null  THEN
        RETURN 'workspace/main-acceptance-template-evidence-not-supported';
      ELSIF "gw_ledger".optional_field(v_issuer_root,'ledger/global-state-root') is not null  THEN
        RETURN 'workspace/main-acceptance-state-evidence-not-supported';
      ELSIF NOT (v_scope_root = "gw_ledger".put_keyword('workspace/main')) THEN
        RETURN 'workspace/main-acceptance-scope-mismatch';
      ELSIF NOT (v_audience_root = "gw_ledger".put_keyword('workspace/members')) THEN
        RETURN 'workspace/main-acceptance-audience-mismatch';
      ELSIF NOT (v_valid_from_root = v_recorded_at_root) THEN
        RETURN 'workspace/main-acceptance-valid-from-mismatch';
      ELSIF v_valid_until_root is not null  THEN
        RETURN 'workspace/main-acceptance-expiry-not-supported';
      ELSIF v_revokes_root is not null  THEN
        RETURN 'workspace/main-acceptance-revocation-not-supported';
      ELSIF NOT (v_metadata_root = v_empty_map) THEN
        RETURN 'workspace/main-acceptance-metadata-not-supported';
      ELSE
        DECLARE
        v_reconstructed BYTEA;
          v_recorded_at BIGINT;
          v_review_vector_error TEXT;
      BEGIN
        v_review_vector_error := "gw_ledger".acceptance_review_vector_error(v_review_roots_root);
          v_recorded_at := "gw_ledger".integer_bigint(v_recorded_at_root);
          v_reconstructed := "gw_ledger".workspace_main_acceptance_value(
            v_workspace_id_root,
            v_authority_root,
            v_expected_root,
            v_candidate_root,
            v_policy_root,
            v_review_roots_root,
            v_recorded_at
          );
          IF v_review_vector_error is not null  THEN
            RETURN v_review_vector_error;
          ELSIF v_recorded_at < 0 THEN
            RETURN 'workspace/invalid-main-acceptance-recorded-at';
          ELSIF NOT (v_id_root = "gw_ledger".put_string(
            "gw_ledger".main_acceptance_id(v_workspace_id_root,v_candidate_root)
          )) THEN
            RETURN 'workspace/main-acceptance-id-not-derived';
          ELSIF NOT (v_claim_root = "gw_ledger".put_keyword('workspace/main-accepted-v1')) THEN
            RETURN 'workspace/unsupported-main-acceptance-claim';
          ELSIF NOT (v_subject_id_root = "gw_ledger".put_string("gw_ledger".proposal_name(v_candidate_root))) THEN
            RETURN 'workspace/main-acceptance-subject-id-mismatch';
          ELSIF NOT (v_issuer_root = "gw_ledger".review_recorded_evidence_value(v_authority_root,v_recorded_at)) THEN
            RETURN 'workspace/noncanonical-main-acceptance-evidence';
          ELSIF NOT (v_extensions_root = "gw_ledger".main_acceptance_extensions_value(v_workspace_id_root,v_expected_root,v_candidate_root)) THEN
            RETURN 'workspace/noncanonical-main-acceptance-extensions';
          ELSIF NOT (i_acceptance_root = v_reconstructed) THEN
            RETURN 'workspace/noncanonical-main-acceptance';
          ELSE
            RETURN null;
          END IF;
      END;
      END IF;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-main/workspace-main-acceptance-valid [480] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_main_acceptance_valid(
  i_acceptance_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    o_row := "gw_ledger".workspace_main_acceptance_row(i_acceptance_root);
    IF o_row is null  THEN
      RETURN false;
    END IF;
    DECLARE
      v_authority_root BYTEA;
      v_candidate_root BYTEA;
      v_expected_root BYTEA;
      v_policy_root BYTEA;
      v_recorded_at BIGINT;
      v_review_roots_root BYTEA;
      v_workspace_id_root BYTEA;
    BEGIN
      v_workspace_id_root := (o_row ->> 'workspace_id_root')::BYTEA;
      v_authority_root := (o_row ->> 'authority_root')::BYTEA;
      v_expected_root := (o_row ->> 'expected_root')::BYTEA;
      v_candidate_root := (o_row ->> 'candidate_root')::BYTEA;
      v_policy_root := (o_row ->> 'policy_root')::BYTEA;
      v_review_roots_root := (o_row ->> 'review_roots_root')::BYTEA;
      v_recorded_at := (o_row ->> 'recorded_at')::BIGINT;
      RETURN "gw_ledger".workspace_main_acceptance_error(i_acceptance_root) IS NULL AND (i_acceptance_root = "gw_ledger".workspace_main_acceptance_value(
        v_workspace_id_root,
        v_authority_root,
        v_expected_root,
        v_candidate_root,
        v_policy_root,
        v_review_roots_root,
        v_recorded_at
      ));
    END;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-main/workspace-main-acceptance-import [509] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_main_acceptance_import(
  i_acceptance_root BYTEA
) RETURNS BYTEA AS $$

  DECLARE
    o_existing JSONB;
  BEGIN
    o_existing := "gw_ledger".workspace_main_acceptance_row(i_acceptance_root);
    IF o_existing is not null  THEN
      IF NOT   ("gw_ledger".workspace_main_acceptance_valid(i_acceptance_root)) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object(
              'status',
              'error',
              'tag',
              'ledger/workspace_main_acceptance_projection_conflict',
              'data',
              null
            ))::TEXT,
          MESSAGE = 'ledger/workspace-main-acceptance-projection-conflict'
        ;
      END IF;
      RETURN i_acceptance_root;
    END IF;
    DECLARE
      o_insert JSONB;
      v_authority_root BYTEA;
      v_candidate_root BYTEA;
      v_error TEXT;
      v_expected_root BYTEA;
      v_extensions_root BYTEA;
      v_issuer_root BYTEA;
      v_policy_root BYTEA;
      v_recorded_at BIGINT;
      v_review_roots_root BYTEA;
      v_workspace_id_root BYTEA;
    BEGIN
      v_error := "gw_ledger".workspace_main_acceptance_error(i_acceptance_root);
      IF NOT (v_error IS NULL) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object(
            'status',
            'error',
            'tag',
            'ledger/invalid_workspace_main_acceptance',
            'data',
            v_error
          ))::TEXT,
          MESSAGE = 'ledger/invalid-workspace-main-acceptance'
        ;
      END IF;
      v_extensions_root := "gw_ledger".field(i_acceptance_root,'record/extensions');
      v_workspace_id_root := "gw_ledger".field(v_extensions_root,'workspace/id');
      v_expected_root := "gw_ledger".optional_field(v_extensions_root,'ref/expected-root');
      v_candidate_root := "gw_ledger".field(i_acceptance_root,'attestation/subject-root');
      v_policy_root := "gw_ledger".field(i_acceptance_root,'attestation/context-root');
      v_review_roots_root := "gw_ledger".field(i_acceptance_root,'attestation/evidence-roots');
      v_issuer_root := "gw_ledger".field(i_acceptance_root,'attestation/issuer-evidence');
      v_authority_root := "gw_ledger".field(v_issuer_root,'ledger/signer');
      v_recorded_at := "gw_ledger".integer_bigint("gw_ledger".field(v_issuer_root,'ledger/timestamp'));
      WITH j_ret AS (  
        INSERT INTO "gw_ledger"."WorkspaceMainAcceptance" (
          "acceptance_root",
          "workspace_id_root",
          "authority_root",
          "expected_root",
          "candidate_root",
          "policy_root",
          "review_roots_root",
          "recorded_at"
        ) VALUES (
          (i_acceptance_root)::BYTEA,
          (v_workspace_id_root)::BYTEA,
          (v_authority_root)::BYTEA,
          (v_expected_root)::BYTEA,
          (v_candidate_root)::BYTEA,
          (v_policy_root)::BYTEA,
          (v_review_roots_root)::BYTEA,
          (v_recorded_at)::BIGINT
        ) RETURNING
          "acceptance_root",
          "workspace_id_root",
          "authority_root",
          "expected_root",
          "candidate_root",
          "policy_root",
          "review_roots_root",
          "recorded_at")
      SELECT to_jsonb(j_ret) FROM j_ret INTO o_insert;
      RETURN i_acceptance_root;
    END;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-main/workspace-main-acceptance-put [554] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_main_acceptance_put(
  i_workspace_id_root BYTEA,
  i_authority_root BYTEA,
  i_expected_root BYTEA,
  i_candidate_root BYTEA,
  i_policy_root BYTEA,
  i_review_roots_root BYTEA,
  i_recorded_at BIGINT
) RETURNS BYTEA AS $$

  DECLARE
    v_review_vector_error TEXT;
    v_root BYTEA;
  BEGIN
    v_review_vector_error := "gw_ledger".acceptance_review_vector_error(i_review_roots_root);
    IF NOT (v_review_vector_error IS NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_main_acceptance_reviews',
          'data',
          v_review_vector_error
        ))::TEXT,
        MESSAGE = 'ledger/invalid-main-acceptance-reviews'
      ;
    END IF;
    IF NOT (i_recorded_at >= 0) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_main_acceptance_recorded_at',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-main-acceptance-recorded-at'
      ;
    END IF;
    v_root := "gw_ledger".workspace_main_acceptance_value(
      i_workspace_id_root,
      i_authority_root,
      i_expected_root,
      i_candidate_root,
      i_policy_root,
      i_review_roots_root,
      i_recorded_at
    );
    RETURN "gw_ledger".workspace_main_acceptance_import(v_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-main/main-policy-selected [578] 
CREATE OR REPLACE FUNCTION "gw_ledger".main_policy_selected(
  i_workspace_id_root BYTEA,
  i_policy_root BYTEA,
  i_authority_root BYTEA
) RETURNS BOOLEAN AS $$

  DECLARE
    o_row JSONB;
  BEGIN
    o_row := "gw_ledger".scoped_ref_row(
      "gw_ledger".main_scope(i_workspace_id_root),
      "gw_ledger".main_policy_ref_name()
    );
    RETURN o_row IS NOT NULL AND ((o_row ->> 'root')::BYTEA = i_policy_root) AND ((o_row ->> 'authorization_root')::BYTEA = i_authority_root);
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-main/main-review-evidence-error-at [594] 
CREATE OR REPLACE FUNCTION "gw_ledger".main_review_evidence_error_at(
  i_workspace_id_root BYTEA,
  i_candidate_root BYTEA,
  i_reviewer_roots_root BYTEA,
  i_review_roots_root BYTEA,
  i_position INTEGER,
  i_count INTEGER
) RETURNS TEXT AS $$
BEGIN
  IF i_position >= i_count THEN
    RETURN null;
  ELSE
    DECLARE
    o_current JSONB;
      o_review JSONB;
      v_review_root BYTEA;
      v_reviewer_root BYTEA;
  BEGIN
    v_reviewer_root := "gw_ledger".cell_ref_child(i_reviewer_roots_root,i_position,'element');
      v_review_root := "gw_ledger".cell_ref_child(i_review_roots_root,i_position,'element');
      o_review := "gw_ledger".workspace_review_row(v_review_root);
      o_current := "gw_ledger".scoped_ref_row(
        "gw_ledger".main_scope(i_workspace_id_root),
        "gw_ledger".review_ref_name(i_candidate_root,v_reviewer_root)
      );
      IF o_review is null  THEN
        RETURN 'workspace/main-acceptance-review-not-found';
      ELSIF NOT "gw_ledger".workspace_review_valid(v_review_root) THEN
        RETURN 'workspace/invalid-main-acceptance-review';
      ELSIF NOT ((o_review ->> 'workspace_id_root')::BYTEA = i_workspace_id_root) THEN
        RETURN 'workspace/main-acceptance-review-workspace-mismatch';
      ELSIF NOT ((o_review ->> 'candidate_root')::BYTEA = i_candidate_root) THEN
        RETURN 'workspace/main-acceptance-review-candidate-mismatch';
      ELSIF NOT ((o_review ->> 'reviewer_root')::BYTEA = v_reviewer_root) THEN
        RETURN 'workspace/main-acceptance-reviewer-position-mismatch';
      ELSIF NOT ((o_review ->> 'decision')::TEXT = 'approve') THEN
        RETURN 'workspace/main-acceptance-review-not-approved';
      ELSIF o_current is null  THEN
        RETURN 'workspace/main-acceptance-review-not-current';
      ELSIF NOT ((o_current ->> 'root')::BYTEA = v_review_root) THEN
        RETURN 'workspace/main-acceptance-review-not-current';
      ELSIF NOT ((o_current ->> 'authorization_root')::BYTEA = v_reviewer_root) THEN
        RETURN 'workspace/main-acceptance-review-authorization-mismatch';
      ELSE
        RETURN "gw_ledger".main_review_evidence_error_at(
          i_workspace_id_root,
          i_candidate_root,
          i_reviewer_roots_root,
          i_review_roots_root,
          i_position + 1,
          i_count
        );
      END IF;
  END;
  END IF;
END;
$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-main/main-review-evidence-error [665] 
CREATE OR REPLACE FUNCTION "gw_ledger".main_review_evidence_error(
  i_workspace_id_root BYTEA,
  i_candidate_root BYTEA,
  i_reviewer_roots_root BYTEA,
  i_review_roots_root BYTEA
) RETURNS TEXT AS $$

  DECLARE
    o_reviewers JSONB;
    o_reviews JSONB;
  BEGIN
    o_reviewers := "gw_ledger".cell_by_hash(i_reviewer_roots_root);
    o_reviews := "gw_ledger".cell_by_hash(i_review_roots_root);
    IF o_reviewers IS NULL OR NOT ((o_reviewers ->> 'type_tag')::SMALLINT = 10) THEN
      RETURN 'workspace/main-policy-reviewers-not-vector';
    ELSIF o_reviews IS NULL OR NOT ((o_reviews ->> 'type_tag')::SMALLINT = 10) THEN
      RETURN 'workspace/main-acceptance-reviews-not-vector';
    ELSE
      DECLARE
      v_review_count INTEGER;
        v_reviewer_count INTEGER;
    BEGIN
      v_reviewer_count := "gw_ledger".cell_ref_count(i_reviewer_roots_root,'element');
        v_review_count := "gw_ledger".cell_ref_count(i_review_roots_root,'element');
        IF NOT (v_reviewer_count = v_review_count) THEN
          RETURN 'workspace/main-acceptance-review-count-mismatch';
        ELSE
          RETURN "gw_ledger".main_review_evidence_error_at(
            i_workspace_id_root,
            i_candidate_root,
            i_reviewer_roots_root,
            i_review_roots_root,
            0,
            v_reviewer_count
          );
        END IF;
    END;
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-main/main-transition-error [699] 
CREATE OR REPLACE FUNCTION "gw_ledger".main_transition_error(
  i_workspace_id_root BYTEA,
  i_authority_root BYTEA,
  i_expected_root BYTEA,
  i_candidate_root BYTEA,
  i_policy_root BYTEA,
  i_review_roots_root BYTEA
) RETURNS TEXT AS $$

  DECLARE
    o_candidate JSONB;
    o_expected JSONB;
    o_policy JSONB;
  BEGIN
    o_policy := "gw_ledger".workspace_main_policy_row(i_policy_root);
    o_candidate := "gw_ledger".workspace_commit_row(i_candidate_root);
    o_expected := CASE WHEN i_expected_root IS NULL THEN null
    ELSE "gw_ledger".workspace_commit_row(i_expected_root)
    END;
    IF o_policy is null  THEN
      RETURN 'workspace/main-policy-not-found';
    ELSIF NOT "gw_ledger".workspace_main_policy_valid(i_policy_root) THEN
      RETURN 'workspace/invalid-main-policy';
    ELSIF NOT ((o_policy ->> 'workspace_id_root')::BYTEA = i_workspace_id_root) THEN
      RETURN 'workspace/main-policy-workspace-mismatch';
    ELSIF NOT ((o_policy ->> 'authority_root')::BYTEA = i_authority_root) THEN
      RETURN 'workspace/main-policy-authority-mismatch';
    ELSIF NOT "gw_ledger".main_policy_selected(i_workspace_id_root,i_policy_root,i_authority_root) THEN
      RETURN 'workspace/main-policy-not-published';
    ELSIF o_candidate is null  THEN
      RETURN 'workspace/main-candidate-not-found';
    ELSIF NOT "gw_ledger".workspace_commit_valid(i_candidate_root) THEN
      RETURN 'workspace/invalid-main-candidate';
    ELSIF NOT ((o_candidate ->> 'workspace_id_root')::BYTEA = i_workspace_id_root) THEN
      RETURN 'workspace/main-candidate-workspace-mismatch';
    ELSIF NOT "gw_ledger".proposal_published(i_workspace_id_root,i_candidate_root) THEN
      RETURN 'workspace/main-candidate-not-proposed';
    ELSIF i_expected_root IS NULL AND NOT ((o_candidate ->> 'parent_count')::INTEGER = 0) THEN
      RETURN 'workspace/main-bootstrap-not-genesis';
    ELSIF i_expected_root IS NOT NULL AND o_expected IS NULL THEN
      RETURN 'workspace/expected-main-not-found';
    ELSIF i_expected_root IS NOT NULL AND NOT "gw_ledger".workspace_commit_valid(i_expected_root) THEN
      RETURN 'workspace/invalid-expected-main';
    ELSIF i_expected_root IS NOT NULL AND NOT ((o_expected ->> 'workspace_id_root')::BYTEA = i_workspace_id_root) THEN
      RETURN 'workspace/expected-main-workspace-mismatch';
    ELSIF i_expected_root IS NOT NULL AND (i_expected_root = i_candidate_root) THEN
      RETURN 'workspace/noop-main-acceptance';
    ELSIF i_expected_root IS NOT NULL AND NOT "gw_ledger".workspace_commit_ancestor(i_expected_root,i_candidate_root) THEN
      RETURN 'workspace/non-fast-forward-main-acceptance';
    ELSE
      RETURN "gw_ledger".main_review_evidence_error(
        i_workspace_id_root,
        i_candidate_root,
        (o_policy ->> 'reviewer_roots_root')::BYTEA,
        i_review_roots_root
      );
    END IF;
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-main/workspace-main-signing-request [791] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_main_signing_request(
  i_network TEXT,
  i_public_key BYTEA,
  i_workspace_id_root BYTEA,
  i_expected_root BYTEA,
  i_candidate_root BYTEA,
  i_policy_root BYTEA,
  i_review_roots_root BYTEA,
  i_recorded_at BIGINT,
  i_cost_limit BIGINT
) RETURNS JSONB AS $$

  DECLARE
    o_head JSONB;
    v_acceptance_root BYTEA;
    v_account_root BYTEA;
    v_address_root BYTEA;
    v_controller_root BYTEA;
    v_expected_controller BYTEA;
    v_op_root BYTEA;
    v_payload BYTEA;
    v_runtime_root BYTEA;
    v_sequence BIGINT;
    v_state_root BYTEA;
    v_transition_error TEXT;
  BEGIN
    o_head := "gw_ledger".head_get(i_network);
    IF NOT (o_head IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/network_missing','data',null))::TEXT,
        MESSAGE = 'ledger/network-missing'
      ;
    END IF;
    IF NOT (i_cost_limit >= 1) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_cost_limit','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-cost-limit'
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
    v_transition_error := "gw_ledger".main_transition_error(
      i_workspace_id_root,
      v_address_root,
      i_expected_root,
      i_candidate_root,
      i_policy_root,
      i_review_roots_root
    );
    IF NOT (v_transition_error IS NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_workspace_main_acceptance',
          'data',
          v_transition_error
        ))::TEXT,
        MESSAGE = 'ledger/invalid-workspace-main-acceptance'
      ;
    END IF;
    IF NOT (i_recorded_at >= 0) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_main_acceptance_recorded_at',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-main-acceptance-recorded-at'
      ;
    END IF;
    v_acceptance_root := "gw_ledger".workspace_main_acceptance_put(
      i_workspace_id_root,
      v_address_root,
      i_expected_root,
      i_candidate_root,
      i_policy_root,
      i_review_roots_root,
      i_recorded_at
    );
    v_op_root := "gw_ledger".constant(v_acceptance_root);
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
      'workspace_id_root',
      encode(i_workspace_id_root,'hex'),
      'scope',
      "gw_ledger".main_scope(i_workspace_id_root),
      'name',
      "gw_ledger".main_ref_name(),
      'expected_root',
      "gw_ledger".root_hex(i_expected_root),
      'candidate_root',
      encode(i_candidate_root,'hex'),
      'policy_root',
      encode(i_policy_root,'hex'),
      'review_roots_root',
      encode(i_review_roots_root,'hex'),
      'recorded_at',
      i_recorded_at,
      'policy',
      'main-acceptance-v1',
      'acceptance_root',
      encode(v_acceptance_root,'hex'),
      'operation_root',
      encode(v_op_root,'hex'),
      'signing_payload',
      encode(v_payload,'hex')
    );
  END;

$$ LANGUAGE 'plpgsql';

-- gwdb.ledger.workspace-main/workspace-main-submit [860] 
CREATE OR REPLACE FUNCTION "gw_ledger".workspace_main_submit(
  i_network TEXT,
  i_public_key BYTEA,
  i_sequence BIGINT,
  i_workspace_id_root BYTEA,
  i_expected_root BYTEA,
  i_candidate_root BYTEA,
  i_policy_root BYTEA,
  i_review_roots_root BYTEA,
  i_recorded_at BIGINT,
  i_cost_limit BIGINT,
  i_signature BYTEA
) RETURNS JSONB AS $$

  DECLARE
    o_cas JSONB;
    o_head JSONB;
    v_acceptance_root BYTEA;
    v_account_root BYTEA;
    v_address_root BYTEA;
    v_cas_status TEXT;
    v_controller_root BYTEA;
    v_current_sequence BIGINT;
    v_expected_controller BYTEA;
    v_name TEXT;
    v_op_root BYTEA;
    v_previous_height BIGINT;
    v_previous_state BYTEA;
    v_runtime_root BYTEA;
    v_scope TEXT;
    v_signing_payload BYTEA;
    v_transition_error TEXT;
  BEGIN
    o_head := "gw_ledger".head_lock(i_network);
    IF NOT (o_head IS NOT NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/network_missing','data',null))::TEXT,
        MESSAGE = 'ledger/network-missing'
      ;
    END IF;
    IF NOT (i_cost_limit >= 1) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object('status','error','tag','ledger/invalid_cost_limit','data',null))::TEXT,
        MESSAGE = 'ledger/invalid-cost-limit'
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
    v_transition_error := "gw_ledger".main_transition_error(
      i_workspace_id_root,
      v_address_root,
      i_expected_root,
      i_candidate_root,
      i_policy_root,
      i_review_roots_root
    );
    IF NOT (v_transition_error IS NULL) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_workspace_main_acceptance',
          'data',
          v_transition_error
        ))::TEXT,
        MESSAGE = 'ledger/invalid-workspace-main-acceptance'
      ;
    END IF;
    IF NOT (i_recorded_at >= 0) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_main_acceptance_recorded_at',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-main-acceptance-recorded-at'
      ;
    END IF;
    v_acceptance_root := "gw_ledger".workspace_main_acceptance_put(
      i_workspace_id_root,
      v_address_root,
      i_expected_root,
      i_candidate_root,
      i_policy_root,
      i_review_roots_root,
      i_recorded_at
    );
    v_op_root := "gw_ledger".constant(v_acceptance_root);
    v_runtime_root := "gw_ledger".put_integer('1');
    v_signing_payload := "gw_ledger".transaction_signing_payload(
      i_network,
      v_address_root,
      i_sequence,
      v_op_root,
      null,
      i_cost_limit,
      v_runtime_root
    );
    IF NOT ("gw_ledger".signature_verify(i_signature,v_signing_payload,i_public_key)) THEN
      RAISE EXCEPTION USING
        DETAIL = (jsonb_build_object(
          'status',
          'error',
          'tag',
          'ledger/invalid_workspace_main_acceptance_signature',
          'data',
          null
        ))::TEXT,
        MESSAGE = 'ledger/invalid-workspace-main-acceptance-signature'
      ;
    END IF;
    v_scope := "gw_ledger".main_scope(i_workspace_id_root);
    v_name := "gw_ledger".main_ref_name();
    o_cas := "gw_ledger".scoped_ref_compare_and_set(v_scope,v_name,i_expected_root,i_candidate_root,i_policy_root);
    v_cas_status := (o_cas ->> 'status')::TEXT;
    IF NOT (v_cas_status = 'ok') THEN
      RETURN o_cas || jsonb_build_object(
        'address',
        encode(v_address_root,'hex'),
        'workspace_id_root',
        encode(i_workspace_id_root,'hex'),
        'candidate_root',
        encode(i_candidate_root,'hex'),
        'policy_root',
        encode(i_policy_root,'hex'),
        'review_roots_root',
        encode(i_review_roots_root,'hex'),
        'recorded_at',
        i_recorded_at,
        'policy',
        'main-acceptance-v1',
        'acceptance_root',
        encode(v_acceptance_root,'hex'),
        'sequence',
        i_sequence
      );
    END IF;
    DECLARE
      o_bound JSONB;
      o_receipt JSONB;
      v_block_root BYTEA;
      v_receipt_root BYTEA;
      v_state_root BYTEA;
      v_transaction_root BYTEA;
    BEGIN
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
        i_recorded_at
      );
      o_receipt := "gw_ledger".transaction_receipt_get(v_receipt_root);
      IF NOT (o_receipt IS NOT NULL) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object('status','error','tag','ledger/missing_receipt','data',null))::TEXT,
          MESSAGE = 'ledger/missing-receipt'
        ;
      END IF;
      IF NOT (((o_receipt ->> 'status')::TEXT = 'ok') AND ((o_receipt ->> 'result_root')::BYTEA = v_acceptance_root)) THEN
        RAISE EXCEPTION USING
          DETAIL = (jsonb_build_object(
            'status',
            'error',
            'tag',
            'ledger/workspace_main_acceptance_receipt_mismatch',
            'data',
            null
          ))::TEXT,
          MESSAGE = 'ledger/workspace-main-acceptance-receipt-mismatch'
        ;
      END IF;
      v_state_root := (o_receipt ->> 'state_root')::BYTEA;
      v_block_root := "gw_ledger".block_commit(
        i_network,
        v_previous_height,
        v_previous_state,
        v_previous_height + 1,
        (o_head ->> 'block_root')::BYTEA,
        v_previous_state,
        v_state_root,
        i_recorded_at,
        "gw_ledger".admission_proposer_root(),
        null,
        jsonb_build_array(encode(v_transaction_root,'hex'))
      );
      o_bound := "gw_ledger".block_transaction_bind(v_block_root,0,v_receipt_root);
      RETURN jsonb_build_object(
        'status',
        'ok',
        'address',
        encode(v_address_root,'hex'),
        'sequence',
        i_sequence,
        'workspace_id_root',
        encode(i_workspace_id_root,'hex'),
        'scope',
        v_scope,
        'name',
        v_name,
        'expected_root',
        "gw_ledger".root_hex(i_expected_root),
        'candidate_root',
        encode(i_candidate_root,'hex'),
        'policy_root',
        encode(i_policy_root,'hex'),
        'review_roots_root',
        encode(i_review_roots_root,'hex'),
        'recorded_at',
        i_recorded_at,
        'policy',
        'main-acceptance-v1',
        'acceptance_root',
        encode(v_acceptance_root,'hex'),
        'ref_version',
        (o_cas ->> 'version')::BIGINT,
        'transaction_root',
        encode(v_transaction_root,'hex'),
        'receipt_root',
        encode(v_receipt_root,'hex'),
        'result_root',
        encode((o_receipt ->> 'result_root')::BYTEA,'hex'),
        'state_root',
        encode(v_state_root,'hex'),
        'block_root',
        encode(v_block_root,'hex')
      );
    END;
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