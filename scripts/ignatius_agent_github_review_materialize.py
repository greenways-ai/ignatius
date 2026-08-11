"""Materialize one exact GitHub review snapshot for an Ignatius signer."""

from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import stat
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

from ignatius_github_common import canonical_json, parse_json, require_map, require_positive_integer, require_string

PROTOCOL = "ignatius.github-review-materialization/0-alpha"
MAX_SNAPSHOT_BYTES = 2 * 1024 * 1024
MAX_REVIEW_BODY_BYTES = 1024 * 1024

_REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
_ROOT = re.compile(r"^[0-9a-f]{64}$")
_VERSION = re.compile(r"^sha256:[0-9a-f]{64}$")
_HEX = re.compile(r"^[0-9a-f]+$")
_ACTIONS = frozenset({"submitted", "edited", "dismissed"})
_STATES = frozenset({"approved", "changes_requested", "commented", "dismissed"})
_ASSOCIATIONS = frozenset(
    {
        "COLLABORATOR",
        "CONTRIBUTOR",
        "FIRST_TIMER",
        "FIRST_TIME_CONTRIBUTOR",
        "MANNEQUIN",
        "MEMBER",
        "NONE",
        "OWNER",
    }
)
_REQUIRED_SNAPSHOT_COLUMNS = frozenset({"version", "canonical_json", "size"})
_SIDECAR_SUFFIXES = ("-journal", "-wal", "-shm")


class MaterializationError(ValueError):
    """Bounded validation failure suitable for operator diagnostics."""


@dataclass(frozen=True)
class DatabaseIdentity:
    device: int
    inode: int


def _fail(code: str) -> MaterializationError:
    return MaterializationError(code)


def _exact_keys(value: dict[str, Any], expected: set[str], name: str) -> None:
    if set(value) != expected:
        raise _fail(f"invalid-{name}-shape")


def _boolean(value: Any, name: str) -> bool:
    if not isinstance(value, bool):
        raise _fail(f"invalid-{name}")
    return value


def _positive(value: Any, name: str) -> int:
    try:
        return require_positive_integer(value, name)
    except ValueError as error:
        raise _fail(f"invalid-{name}") from error


def _text(value: Any, name: str) -> str:
    try:
        return require_string(value, name)
    except ValueError as error:
        raise _fail(f"invalid-{name}") from error


def _timestamp(value: Any, name: str) -> str:
    text = _text(value, name)
    if not text.endswith("Z"):
        raise _fail(f"invalid-{name}")
    try:
        datetime.fromisoformat(text[:-1] + "+00:00")
    except ValueError as error:
        raise _fail(f"invalid-{name}") from error
    return text


def _root(value: Any, name: str) -> str:
    text = _text(value, name)
    if not _ROOT.fullmatch(text):
        raise _fail(f"invalid-{name}")
    return text


def _object_id(value: Any, name: str, *, width: int | None = None) -> str:
    text = _text(value, name)
    if not _HEX.fullmatch(text):
        raise _fail(f"invalid-{name}")
    if width is None and len(text) not in {40, 64}:
        raise _fail(f"invalid-{name}")
    if width is not None and len(text) != width:
        raise _fail(f"invalid-{name}")
    return text


def _repository(value: Any, name: str) -> dict[str, Any]:
    try:
        item = require_map(value, name)
    except ValueError as error:
        raise _fail(f"invalid-{name}-shape") from error
    _exact_keys(item, {"id", "node_id", "full_name"}, name)
    full_name = _text(item.get("full_name"), f"{name}-full-name")
    if not _REPOSITORY.fullmatch(full_name):
        raise _fail(f"invalid-{name}-full-name")
    return {
        "id": _positive(item.get("id"), f"{name}-id"),
        "node_id": _text(item.get("node_id"), f"{name}-node-id"),
        "full_name": full_name,
    }


def _identity(value: Any, name: str) -> dict[str, Any]:
    try:
        item = require_map(value, name)
    except ValueError as error:
        raise _fail(f"invalid-{name}-shape") from error
    _exact_keys(item, {"id", "node_id", "login"}, name)
    return {
        "id": _positive(item.get("id"), f"{name}-id"),
        "node_id": _text(item.get("node_id"), f"{name}-node-id"),
        "login": _text(item.get("login"), f"{name}-login"),
    }


def _ref(value: Any, name: str) -> str:
    text = _text(value, name)
    if text.startswith("/") or text.endswith("/") or "//" in text or ".." in text:
        raise _fail(f"invalid-{name}")
    if any(char.isspace() or char in "~^:?*[\\" for char in text):
        raise _fail(f"invalid-{name}")
    return text


def _private_regular(path: Path, label: str) -> tuple[os.stat_result, DatabaseIdentity]:
    try:
        value = path.lstat()
    except OSError as error:
        raise _fail(f"{label}-unavailable") from error
    if stat.S_ISLNK(value.st_mode):
        raise _fail(f"{label}-symlink")
    if not stat.S_ISREG(value.st_mode):
        raise _fail(f"{label}-not-regular")
    if value.st_mode & 0o077:
        raise _fail(f"{label}-not-private")
    return value, DatabaseIdentity(value.st_dev, value.st_ino)


def _check_sidecars(database: Path) -> None:
    for suffix in _SIDECAR_SUFFIXES:
        sidecar = Path(str(database) + suffix)
        try:
            exists = sidecar.exists() or sidecar.is_symlink()
        except OSError as error:
            raise _fail("database-sidecar-unavailable") from error
        if not exists:
            continue
        _private_regular(sidecar, "database-sidecar")


def _read_snapshot(database: Path, version: str) -> bytes:
    _private_regular(database, "database")
    _check_sidecars(database)
    _, before = _private_regular(database, "database")
    try:
        connection = sqlite3.connect(
            database.absolute().as_uri() + "?mode=ro",
            uri=True,
            timeout=5,
            isolation_level=None,
        )
    except sqlite3.Error as error:
        raise _fail("database-open-failed") from error

    try:
        connection.execute("PRAGMA query_only = ON")
        connection.execute("PRAGMA trusted_schema = OFF")
        connection.execute("PRAGMA busy_timeout = 5000")
        quick_check = connection.execute("PRAGMA quick_check(1)").fetchone()
        if quick_check is None or quick_check[0] != "ok":
            raise _fail("database-integrity-failed")
        table = connection.execute(
            "SELECT 1 FROM sqlite_schema WHERE type='table' AND name='github_snapshot'"
        ).fetchone()
        if table is None:
            raise _fail("snapshot-table-missing")
        columns = {
            str(row[1])
            for row in connection.execute("PRAGMA table_xinfo('github_snapshot')")
            if isinstance(row[1], str)
        }
        if not _REQUIRED_SNAPSHOT_COLUMNS.issubset(columns):
            raise _fail("snapshot-table-invalid")
        row = connection.execute(
            "SELECT canonical_json, size FROM github_snapshot WHERE version = ?",
            (version,),
        ).fetchone()
        if row is None:
            raise _fail("snapshot-not-found")
        raw, declared_size = row
        if not isinstance(raw, (bytes, bytearray, memoryview)):
            raise _fail("snapshot-bytes-invalid")
        snapshot = bytes(raw)
        if not isinstance(declared_size, int) or isinstance(declared_size, bool):
            raise _fail("snapshot-size-invalid")
        if declared_size != len(snapshot):
            raise _fail("snapshot-size-mismatch")
        if len(snapshot) > MAX_SNAPSHOT_BYTES:
            raise _fail("snapshot-too-large")
    except sqlite3.Error as error:
        raise _fail("database-read-failed") from error
    finally:
        connection.close()

    _, after = _private_regular(database, "database")
    _check_sidecars(database)
    if after != before:
        raise _fail("database-replaced-during-read")
    return snapshot


def _validate_snapshot(
    snapshot: bytes,
    version: str,
    *,
    expected_workspace: str,
    expected_repository: str,
    expected_candidate_root: str,
    expected_origin_root: str,
) -> dict[str, Any]:
    digest = hashlib.sha256(snapshot).hexdigest()
    if version != f"sha256:{digest}":
        raise _fail("snapshot-version-mismatch")
    try:
        value = parse_json(snapshot)
    except (json.JSONDecodeError, ValueError, UnicodeDecodeError) as error:
        raise _fail("snapshot-json-invalid") from error
    if canonical_json(value) != snapshot:
        raise _fail("snapshot-json-not-canonical")
    _exact_keys(
        value,
        {"repository", "pull_request", "review", "actor", "proposal", "lifecycle"},
        "snapshot",
    )

    repository = _repository(value.get("repository"), "repository")
    if repository["full_name"] != expected_repository:
        raise _fail("repository-mismatch")

    pull = require_map(value.get("pull_request"), "pull_request")
    _exact_keys(
        pull,
        {"id", "node_id", "number", "state", "draft", "merged", "head", "base"},
        "pull-request",
    )
    pull_state = _text(pull.get("state"), "pull-request-state")
    if pull_state not in {"open", "closed"}:
        raise _fail("invalid-pull-request-state")
    pull_draft = _boolean(pull.get("draft"), "pull-request-draft")
    pull_merged = _boolean(pull.get("merged"), "pull-request-merged")
    if pull_state == "open" and pull_merged:
        raise _fail("invalid-pull-request-state")
    pull_number = _positive(pull.get("number"), "pull-request-number")
    pull_id = _positive(pull.get("id"), "pull-request-id")
    pull_node_id = _text(pull.get("node_id"), "pull-request-node-id")

    head = require_map(pull.get("head"), "pull_request.head")
    base = require_map(pull.get("base"), "pull_request.base")
    _exact_keys(head, {"repository", "ref", "sha"}, "pull-request-head")
    _exact_keys(base, {"repository", "ref", "sha"}, "pull-request-base")
    head_repository = _repository(head.get("repository"), "head-repository")
    base_repository = _repository(base.get("repository"), "base-repository")
    if base_repository != repository:
        raise _fail("base-repository-mismatch")
    head_ref = _ref(head.get("ref"), "head-ref")
    base_ref = _ref(base.get("ref"), "base-ref")
    head_sha = _object_id(head.get("sha"), "head-sha")
    base_sha = _object_id(base.get("sha"), "base-sha", width=len(head_sha))

    review = require_map(value.get("review"), "review")
    _exact_keys(
        review,
        {
            "id",
            "node_id",
            "author",
            "body",
            "state",
            "commit_id",
            "submitted_at",
            "author_association",
        },
        "review",
    )
    review_id = _positive(review.get("id"), "review-id")
    review_node_id = _text(review.get("node_id"), "review-node-id")
    author = _identity(review.get("author"), "review-author")
    actor = _identity(value.get("actor"), "review-actor")
    review_state = _text(review.get("state"), "review-state")
    if review_state not in _STATES:
        raise _fail("invalid-review-state")
    review_commit = _object_id(review.get("commit_id"), "review-commit", width=len(head_sha))
    submitted_at = _timestamp(review.get("submitted_at"), "review-submitted-at")
    association = _text(review.get("author_association"), "review-author-association")
    if association not in _ASSOCIATIONS:
        raise _fail("invalid-review-author-association")
    body = review.get("body")
    if body is not None and not isinstance(body, str):
        raise _fail("invalid-review-body")
    body_bytes = b"" if body is None else body.encode("utf-8")
    if len(body_bytes) > MAX_REVIEW_BODY_BYTES:
        raise _fail("review-body-too-large")

    proposal = require_map(value.get("proposal"), "proposal")
    _exact_keys(proposal, {"workspace_id", "candidate_root", "origin_root"}, "proposal")
    workspace = _text(proposal.get("workspace_id"), "workspace-id")
    candidate_root = _root(proposal.get("candidate_root"), "candidate-root")
    origin_root = _root(proposal.get("origin_root"), "origin-root")
    if workspace != expected_workspace:
        raise _fail("workspace-mismatch")
    if candidate_root != expected_candidate_root:
        raise _fail("candidate-root-mismatch")
    if origin_root != expected_origin_root:
        raise _fail("origin-root-mismatch")

    lifecycle = require_map(value.get("lifecycle"), "lifecycle")
    _exact_keys(lifecycle, {"action"}, "lifecycle")
    action = _text(lifecycle.get("action"), "review-action")
    if action not in _ACTIONS:
        raise _fail("invalid-review-action")
    if action == "dismissed" and review_state != "dismissed":
        raise _fail("invalid-review-action-state")
    if action != "dismissed" and review_state == "dismissed":
        raise _fail("invalid-review-action-state")
    if action in {"submitted", "edited"} and actor["id"] != author["id"]:
        raise _fail("review-actor-mismatch")

    return {
        "digest": digest,
        "size": len(snapshot),
        "repository": repository,
        "pull_request": {
            "id": pull_id,
            "node_id": pull_node_id,
            "number": pull_number,
            "state": pull_state,
            "draft": pull_draft,
            "merged": pull_merged,
            "head": {
                "repository": head_repository,
                "ref": head_ref,
                "sha": head_sha,
            },
            "base": {
                "repository": base_repository,
                "ref": base_ref,
                "sha": base_sha,
            },
        },
        "review": {
            "id": review_id,
            "node_id": review_node_id,
            "author": author,
            "actor": actor,
            "state": review_state,
            "action": action,
            "commit_sha": review_commit,
            "current_head": review_commit == head_sha,
            "submitted_at": submitted_at,
            "author_association": association,
            "body": body,
            "body_bytes": body_bytes,
        },
        "proposal": {
            "workspace_id": workspace,
            "candidate_root": candidate_root,
            "origin_root": origin_root,
        },
    }


def materialize_review(
    database: Path,
    version: str,
    *,
    expected_workspace: str,
    expected_repository: str,
    expected_candidate_root: str,
    expected_origin_root: str,
    redact_body: bool = False,
) -> dict[str, Any]:
    if not _VERSION.fullmatch(version):
        raise _fail("invalid-snapshot-version")
    if not _REPOSITORY.fullmatch(expected_repository):
        raise _fail("invalid-expected-repository")
    _text(expected_workspace, "expected-workspace")
    _root(expected_candidate_root, "expected-candidate-root")
    _root(expected_origin_root, "expected-origin-root")

    snapshot = _read_snapshot(database, version)
    value = _validate_snapshot(
        snapshot,
        version,
        expected_workspace=expected_workspace,
        expected_repository=expected_repository,
        expected_candidate_root=expected_candidate_root,
        expected_origin_root=expected_origin_root,
    )
    review = value["review"]
    body_bytes = review.pop("body_bytes")
    body = review.pop("body")
    review["body"] = {
        "included": not redact_body,
        "is_null": body is None,
        "present": body not in {None, ""},
        "sha256": hashlib.sha256(body_bytes).hexdigest(),
        "utf8_bytes": len(body_bytes),
        "text": None if redact_body else body,
    }
    proposal = value["proposal"]
    pull = value["pull_request"]
    resource_id = (
        f"github/{expected_repository}/pulls/{pull['number']}/reviews/{review['id']}"
    )
    return {
        "protocol": PROTOCOL,
        "source": {
            "resource_id": resource_id,
            "snapshot_version": version,
            "snapshot_sha256": value["digest"],
            "snapshot_size": value["size"],
        },
        "proposal": {
            **proposal,
            "ref_name": f"proposal/{proposal['candidate_root']}",
        },
        "pull_request": pull,
        "review": review,
        "canonical_review": {
            "policy": "review-decision-v1",
            "subject_id": f"proposal/{proposal['candidate_root']}",
            "subject_root": proposal["candidate_root"],
            "allowed_decisions": ["approve", "reject", "withdraw"],
            "selected_decision": None,
            "reviewer_root": None,
            "expected_review_root": None,
            "signing_required": True,
            "provider_state_authoritative": False,
        },
    }
