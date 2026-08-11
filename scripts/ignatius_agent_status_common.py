"""Shared validation and disclosure rules for Agent Workflow status."""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

PROTOCOL = "ignatius.agent-workflow-status/0-alpha"
SAFE_ROLE = re.compile(r"^[a-z][a-z0-9_.-]{0,63}$")
SAFE_IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,127}$")

STATE_BUCKETS: Mapping[str, tuple[str, ...]] = {
    "pending": (
        "available",
        "pending",
        "queued",
        "ready",
        "retry",
        "retryable",
        "scheduled",
        "waiting",
    ),
    "in_flight": (
        "claimed",
        "delivering",
        "executing",
        "in_flight",
        "leased",
        "processing",
        "running",
    ),
    "successful": (
        "accepted",
        "committed",
        "complete",
        "completed",
        "delivered",
        "done",
        "succeeded",
        "successful",
    ),
    "terminal_failure": (
        "canceled",
        "cancelled",
        "dead",
        "dead_letter",
        "exhausted",
        "failed",
        "rejected",
        "terminal_failure",
    ),
}

STATE_COLUMNS = ("state", "status")
ATTEMPT_COLUMNS = ("attempts", "attempt_count", "delivery_attempts", "retry_count")
GENERATION_COLUMNS = (
    "fencing_generation",
    "lease_generation",
    "generation",
    "fence",
)
LEASE_COLUMNS = (
    "lease_expires_at",
    "lease_until",
    "leased_until",
    "claim_expires_at",
    "delivery_lease_expires_at",
)
DUE_COLUMNS = (
    "next_attempt_at",
    "available_at",
    "retry_at",
    "not_before",
    "due_at",
)
SIDE_SUFFIXES = ("-wal", "-shm", "-journal")
HEALTH_RANK = {"healthy": 0, "attention": 1, "blocked": 2}


@dataclass(frozen=True)
class Binding:
    role: str
    path: Path


@dataclass(frozen=True)
class Clock:
    value: datetime

    @property
    def epoch(self) -> float:
        return self.value.timestamp()

    @property
    def iso(self) -> str:
        return self.value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def parse_clock(value: str | None) -> Clock:
    if value is None:
        return Clock(datetime.now(timezone.utc))
    candidate = value[:-1] + "+00:00" if value.endswith("Z") else value
    parsed = datetime.fromisoformat(candidate)
    if parsed.tzinfo is None:
        raise ValueError("--now must include an explicit UTC offset")
    return Clock(parsed.astimezone(timezone.utc))


def parse_binding(value: str) -> Binding:
    role, separator, raw_path = value.partition("=")
    if not separator or not SAFE_ROLE.fullmatch(role) or not raw_path:
        raise ValueError("database bindings must use ROLE=PATH with a safe role")
    if "\x00" in raw_path:
        raise ValueError("database path contains a NUL byte")
    return Binding(role=role, path=Path(os.path.abspath(os.path.normpath(raw_path))))


def path_sha256(path: Path) -> str:
    return "sha256:" + hashlib.sha256(os.fsencode(str(path))).hexdigest()


def name_view(name: str) -> dict[str, str]:
    if SAFE_IDENTIFIER.fullmatch(name):
        return {"name": name}
    return {"name_sha256": "sha256:" + hashlib.sha256(name.encode("utf-8")).hexdigest()}


def merge_health(*values: str) -> str:
    return max(values, key=lambda value: HEALTH_RANK[value], default="healthy")


def quote_identifier(value: str) -> str:
    return '"' + value.replace('"', '""') + '"'


def existing_components(path: Path) -> Iterable[Path]:
    absolute = path if path.is_absolute() else Path(os.path.abspath(path))
    parts = absolute.parts
    if not parts:
        return
    current = Path(parts[0])
    yield current
    for part in parts[1:]:
        current = current / part
        yield current


def lstat_reason(path: Path) -> tuple[os.stat_result | None, str | None]:
    try:
        for component in existing_components(path):
            try:
                component_stat = component.lstat()
            except FileNotFoundError:
                break
            if stat.S_ISLNK(component_stat.st_mode):
                return None, "database-symlink"
        result = path.lstat()
    except FileNotFoundError:
        return None, "database-missing"
    except OSError:
        return None, "database-stat-error"
    if stat.S_ISLNK(result.st_mode):
        return None, "database-symlink"
    if not stat.S_ISREG(result.st_mode):
        return None, "database-not-regular"
    return result, None


def private_mode(mode: int) -> bool:
    return stat.S_IMODE(mode) & 0o077 == 0


def file_view(path: Path, database_stat: os.stat_result) -> tuple[dict[str, Any], list[str]]:
    reasons: list[str] = []
    database_mode = stat.S_IMODE(database_stat.st_mode)
    if not private_mode(database_stat.st_mode):
        reasons.append("database-mode-not-private")

    sidecars_present = 0
    sidecars_private = 0
    sidecars_symlink = 0
    sidecars_not_regular = 0
    for suffix in SIDE_SUFFIXES:
        sidecar = Path(str(path) + suffix)
        try:
            sidecar_stat = sidecar.lstat()
        except FileNotFoundError:
            continue
        except OSError:
            reasons.append("sidecar-stat-error")
            continue
        sidecars_present += 1
        if stat.S_ISLNK(sidecar_stat.st_mode):
            sidecars_symlink += 1
            reasons.append("sidecar-symlink")
        elif not stat.S_ISREG(sidecar_stat.st_mode):
            sidecars_not_regular += 1
            reasons.append("sidecar-not-regular")
        elif private_mode(sidecar_stat.st_mode):
            sidecars_private += 1
        else:
            reasons.append("sidecar-mode-not-private")

    return (
        {
            "mode": f"{database_mode:04o}",
            "private": private_mode(database_stat.st_mode),
            "sidecars": {
                "present": sidecars_present,
                "private": sidecars_private,
                "symlink": sidecars_symlink,
                "not_regular": sidecars_not_regular,
            },
        },
        sorted(set(reasons)),
    )


def first_present(columns: set[str], candidates: Sequence[str]) -> str | None:
    return next((candidate for candidate in candidates if candidate in columns), None)
