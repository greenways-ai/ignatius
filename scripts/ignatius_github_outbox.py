"""SQLite durability boundary for verified GitHub deliveries and exact snapshots."""

from __future__ import annotations

import hashlib
import sqlite3
from pathlib import Path
from typing import Any, Sequence

from ignatius_github_common import edn

SCHEMA = """
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS github_snapshot (
  version TEXT PRIMARY KEY,
  canonical_json BLOB NOT NULL,
  size INTEGER NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS github_delivery (
  delivery_id TEXT PRIMARY KEY KEY,
  body_sha256 TEXT NOT NULL,
  snapshot_version TEXT NOT NULL,
  event_vector_edn TEXT NOT NULL,
  received_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (snapshot_version) REFERENCES github_snapshot(version)
);
CREATE TABLE IF NOT EXISTS github_outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  delivery_id TEXT NOT NULL,
  position INTEGER NOT NULL,
  event_edn TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending'
    CHECK (state IN ('pending', 'delivered')),
  attempts INTEGER NOT NULL DEFAULT 0,
  transaction_root TEXT,
  delivered_at TEXT,
  UNIQUE (delivery_id, position),
  FOREIGN KEY (delivery_id) REFERENCES github_delivery(delivery_id) ON DELETE CASCADE
);
"""


def record_delivery(
    database: str,
    *,
    delivery_id: str,
    body: bytes,
    snapshot_version: str,
    snapshot_json: bytes,
    events: Sequence[dict[Any, Any]],
) -> str:
    Path(database).parent.mkdir(parents=True, exist_ok=True)
    body_sha256 = hashlib.sha256(body).hexdigest()
    vector_edn = edn(events)
    connection = sqlite3.connect(database, timeout=30, isolation_level=None)
    try:
        connection.executescript(SCHEMA)
        connection.execute("BEGIN IMMEDIATE")
        snapshot = connection.execute(
            "SELECT canonical_json FROM github_snapshot WHERE version = ?",
            (snapshot_version,),
        ).fetchone()
        if snapshot is not None and bytes(snapshot[0]) != snapshot_json:
            raise ValueError("snapshot version collision")
        connection.execute(
            "INSERT OR IGNORE INTO github_snapshot(version, canonical_json, size) VALUES (?, ?, ?)",
            (snapshot_version, snapshot_json, len(snapshot_json)),
        )
        existing = connection.execute(
            "SELECT body_sha256, snapshot_version, event_vector_edn FROM github_delivery WHERE delivery_id = ?",
            (delivery_id,),
        ).fetchone()
        expected = (body_sha256, snapshot_version, vector_edn)
        if existing is not None:
            if existing != expected:
                raise ValueError("GitHub delivery ID already has different content")
            connection.commit()
            return "replayed"
        connection.execute(
            "INSERT INTO github_delivery(delivery_id, body_sha256, snapshot_version, event_vector_edn) VALUES (?, ?, ?, ?)",
            (delivery_id, body_sha256, snapshot_version, vector_edn),
        )
        for position, event in enumerate(events):
            connection.execute(
                "INSERT INTO github_outbox(delivery_id, position, event_edn) VALUES (?, ?, ?)",
                (delivery_id, position, edn(event)),
            )
        connection.commit()
        return "queued"
    except Exception:
        if connection.in_transaction:
            connection.rollback()
        raise
    finally:
        connection.close()
