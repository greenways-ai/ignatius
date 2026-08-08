"""Read-only SQLite aggregation for Agent Workflow operational status."""

from __future__ import annotations

import hashlib
import sqlite3
from typing import Any, Sequence

from ignatius_agent_status_common import (
    ATTEMPT_COLUMNS,
    DUE_COLUMNS,
    GENERATION_COLUMNS,
    LEASE_COLUMNS,
    SAFE_IDENTIFIER,
    STATE_BUCKETS,
    STATE_COLUMNS,
    Binding,
    Clock,
    file_view,
    first_present,
    lstat_reason,
    merge_health,
    name_view,
    path_sha256,
    quote_identifier,
)


def state_case(column: str) -> str:
    normalized = f"lower(trim(CAST({quote_identifier(column)} AS TEXT)))"
    clauses: list[str] = []
    for bucket, values in STATE_BUCKETS.items():
        literals = ",".join("'" + value.replace("'", "''") + "'" for value in values)
        clauses.append(f"WHEN {normalized} IN ({literals}) THEN '{bucket}'")
    return "CASE " + " ".join(clauses) + " ELSE 'unknown' END"


def temporal_due_expression(column: str) -> str:
    identifier = quote_identifier(column)
    return f"""
        CASE
          WHEN {identifier} IS NULL THEN 1
          WHEN typeof({identifier}) IN ('integer','real')
            THEN CAST({identifier} AS REAL) <= ?
          WHEN typeof({identifier}) = 'text'
            THEN julianday({identifier}) IS NOT NULL
             AND julianday({identifier}) <= julianday(?)
          ELSE 0
        END
    """


def temporal_expired_expression(column: str) -> str:
    identifier = quote_identifier(column)
    return f"""
        CASE
          WHEN {identifier} IS NULL THEN 0
          WHEN typeof({identifier}) IN ('integer','real')
            THEN CAST({identifier} AS REAL) <= ?
          WHEN typeof({identifier}) = 'text'
            THEN julianday({identifier}) IS NOT NULL
             AND julianday({identifier}) <= julianday(?)
          ELSE 0
        END
    """


def numeric_summary(
    connection: sqlite3.Connection,
    table: str,
    column: str | None,
) -> dict[str, int | None]:
    if column is None:
        return {"rows": 0, "minimum": None, "maximum": None, "total": 0, "negative": 0}
    table_name = quote_identifier(table)
    identifier = quote_identifier(column)
    row = connection.execute(
        f"""
        SELECT
          SUM(CASE WHEN typeof({identifier}) IN ('integer','real') THEN 1 ELSE 0 END),
          MIN(
            CASE WHEN typeof({identifier}) IN ('integer','real')
              THEN CAST({identifier} AS INTEGER)
            END
          ),
          MAX(
            CASE WHEN typeof({identifier}) IN ('integer','real')
              THEN CAST({identifier} AS INTEGER)
            END
          ),
          COALESCE(
            SUM(
              CASE WHEN typeof({identifier}) IN ('integer','real')
                THEN CAST({identifier} AS INTEGER)
                ELSE 0
              END
            ),
            0
          ),
          SUM(
            CASE
              WHEN typeof({identifier}) IN ('integer','real')
               AND CAST({identifier} AS INTEGER) < 0
                THEN 1
              ELSE 0
            END
          )
        FROM {table_name}
        """
    ).fetchone()
    assert row is not None
    return {
        "rows": int(row[0] or 0),
        "minimum": int(row[1]) if row[1] is not None else None,
        "maximum": int(row[2]) if row[2] is not None else None,
        "total": int(row[3] or 0),
        "negative": int(row[4] or 0),
    }


def table_view(connection: sqlite3.Connection, table: str, clock: Clock) -> dict[str, Any]:
    result: dict[str, Any] = {**name_view(table)}
    if not SAFE_IDENTIFIER.fullmatch(table):
        result.update(
            {
                "health": "blocked",
                "reasons": ["unsafe-table-name"],
                "states": {
                    "pending": 0,
                    "in_flight": 0,
                    "successful": 0,
                    "terminal_failure": 0,
                    "unknown": 0,
                },
            }
        )
        return result

    column_rows = connection.execute(
        "SELECT name FROM pragma_table_xinfo(?) WHERE hidden = 0 ORDER BY cid",
        (table,),
    ).fetchall()
    columns = {str(row[0]) for row in column_rows if isinstance(row[0], str)}
    state_column = first_present(columns, STATE_COLUMNS)
    if state_column is None:
        result.update({"health": "healthy", "ignored": True, "reasons": []})
        return result

    attempts_column = first_present(columns, ATTEMPT_COLUMNS)
    generation_column = first_present(columns, GENERATION_COLUMNS)
    lease_column = first_present(columns, LEASE_COLUMNS)
    due_column = first_present(columns, DUE_COLUMNS)
    table_name = quote_identifier(table)
    bucket = state_case(state_column)

    counts = {
        "pending": 0,
        "in_flight": 0,
        "successful": 0,
        "terminal_failure": 0,
        "unknown": 0,
    }
    bucket_query = (
        f"SELECT bucket, COUNT(*) "
        f"FROM (SELECT {bucket} AS bucket FROM {table_name}) "
        "GROUP BY bucket"
    )
    for row in connection.execute(bucket_query):
        label = str(row[0])
        if label in counts:
            counts[label] = int(row[1])

    pending_condition = f"({bucket}) = 'pending'"
    in_flight_condition = f"({bucket}) = 'in_flight'"
    if due_column is None:
        due_attempts = counts["pending"]
    else:
        due_query = (
            f"SELECT COUNT(*) FROM {table_name} "
            f"WHERE {pending_condition} "
            f"AND ({temporal_due_expression(due_column)})"
        )
        due_attempts = int(
            connection.execute(
                due_query,
                (clock.epoch, clock.iso),
            ).fetchone()[0]
        )
    if lease_column is None:
        expired_leases = 0
    else:
        expired_query = (
            f"SELECT COUNT(*) FROM {table_name} "
            f"WHERE {in_flight_condition} "
            f"AND ({temporal_expired_expression(lease_column)})"
        )
        expired_leases = int(
            connection.execute(
                expired_query,
                (clock.epoch, clock.iso),
            ).fetchone()[0]
        )

    attempts = numeric_summary(connection, table, attempts_column)
    generations = numeric_summary(connection, table, generation_column)
    reasons: list[str] = []
    health = "healthy"
    if counts["unknown"]:
        reasons.append("unknown-operational-state")
        health = "blocked"
    if counts["terminal_failure"]:
        reasons.append("terminal-failure-present")
        health = "blocked"
    if attempts["negative"]:
        reasons.append("negative-attempt-count")
        health = "blocked"
    if generations["negative"]:
        reasons.append("negative-fencing-generation")
        health = "blocked"
    if health != "blocked" and (
        counts["pending"]
        or counts["in_flight"]
        or due_attempts
        or expired_leases
        or (attempts["maximum"] or 0) > 0
    ):
        health = "attention"
    if due_attempts:
        reasons.append("due-attempt-present")
    if expired_leases:
        reasons.append("expired-lease-present")
    if counts["pending"]:
        reasons.append("pending-work-present")
    if counts["in_flight"]:
        reasons.append("in-flight-work-present")
    if (attempts["maximum"] or 0) > 0:
        reasons.append("retry-history-present")

    result.update(
        {
            "health": health,
            "reasons": sorted(set(reasons)),
            "states": counts,
            "due_attempts": due_attempts,
            "expired_leases": expired_leases,
            "attempts": attempts,
            "fencing_generations": generations,
        }
    )
    return result


def empty_counts() -> dict[str, int]:
    return {
        "pending": 0,
        "in_flight": 0,
        "successful": 0,
        "terminal_failure": 0,
        "unknown": 0,
        "due_attempts": 0,
        "expired_leases": 0,
    }


def summarize_tables(tables: Sequence[dict[str, Any]]) -> dict[str, int]:
    summary = empty_counts()
    for table in tables:
        states = table.get("states", {})
        for key in ("pending", "in_flight", "successful", "terminal_failure", "unknown"):
            summary[key] += int(states.get(key, 0))
        summary["due_attempts"] += int(table.get("due_attempts", 0))
        summary["expired_leases"] += int(table.get("expired_leases", 0))
    return summary


def blocked_database(
    binding: Binding,
    reason: str,
    *,
    file_data: dict[str, Any] | None = None,
) -> dict[str, Any]:
    value: dict[str, Any] = {
        "role": binding.role,
        "path_sha256": path_sha256(binding.path),
        "health": "blocked",
        "reasons": [reason],
        "tables": [],
        "summary": empty_counts(),
    }
    if file_data is not None:
        value["file"] = file_data
    return value


def inspect_database(binding: Binding, clock: Clock) -> dict[str, Any]:
    database_stat, path_reason = lstat_reason(binding.path)
    if path_reason is not None or database_stat is None:
        return blocked_database(binding, path_reason or "database-stat-error")

    file_data, file_reasons = file_view(binding.path, database_stat)
    before_identity = (database_stat.st_dev, database_stat.st_ino)
    try:
        connection = sqlite3.connect(
            binding.path.as_uri() + "?mode=ro",
            uri=True,
            timeout=5,
            isolation_level=None,
        )
    except sqlite3.Error:
        return blocked_database(binding, "sqlite-open-error", file_data=file_data)

    tables: list[dict[str, Any]] = []
    reasons = list(file_reasons)
    try:
        connection.execute("PRAGMA query_only = ON")
        connection.execute("PRAGMA trusted_schema = OFF")
        connection.execute("PRAGMA busy_timeout = 5000")
        quick_check = connection.execute("PRAGMA quick_check(1)").fetchone()
        if quick_check is None or quick_check[0] != "ok":
            reasons.append("sqlite-quick-check-failed")
        table_rows = connection.execute(
            "SELECT name FROM sqlite_schema "
            "WHERE type = 'table' "
            "AND name NOT LIKE 'sqlite_%' "
            "ORDER BY name"
        ).fetchall()
        for row in table_rows:
            name = row[0]
            if not isinstance(name, str):
                tables.append(
                    {
                        "name_sha256": "sha256:"
                        + hashlib.sha256(repr(name).encode()).hexdigest(),
                        "health": "blocked",
                        "reasons": ["non-text-table-name"],
                        "states": {
                            "pending": 0,
                            "in_flight": 0,
                            "successful": 0,
                            "terminal_failure": 0,
                            "unknown": 0,
                        },
                    }
                )
                continue
            tables.append(table_view(connection, name, clock))
    except sqlite3.Error:
        reasons.append("sqlite-read-error")
    finally:
        connection.close()

    after_stat, after_reason = lstat_reason(binding.path)
    if after_reason is not None or after_stat is None:
        reasons.append("database-changed-during-read")
    elif (after_stat.st_dev, after_stat.st_ino) != before_identity:
        reasons.append("database-replaced-during-read")

    operational_tables = [table for table in tables if not table.get("ignored", False)]
    if not operational_tables:
        reasons.append("no-operational-state-table")
    table_health = merge_health(
        *(table.get("health", "blocked") for table in operational_tables)
    )
    file_health = "blocked" if file_reasons else "healthy"
    reason_health = "blocked" if any(
        reason
        in {
            "database-changed-during-read",
            "database-replaced-during-read",
            "no-operational-state-table",
            "sqlite-quick-check-failed",
            "sqlite-read-error",
        }
        for reason in reasons
    ) else "healthy"
    health = merge_health(table_health, file_health, reason_health)
    summary = summarize_tables(operational_tables)
    return {
        "role": binding.role,
        "path_sha256": path_sha256(binding.path),
        "health": health,
        "reasons": sorted(set(reasons)),
        "file": file_data,
        "tables": tables,
        "summary": summary,
    }


def summarize_databases(databases: Sequence[dict[str, Any]]) -> dict[str, int]:
    summary = empty_counts()
    summary.update({"databases": len(databases), "healthy": 0, "attention": 0, "blocked": 0})
    for database in databases:
        health = str(database["health"])
        summary[health] += 1
        database_summary = database["summary"]
        for key in empty_counts():
            summary[key] += int(database_summary[key])
    return summary
