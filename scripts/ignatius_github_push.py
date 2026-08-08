"""Verified GitHub push deliveries enriched into exact Git resource versions."""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from typing import Any

from ignatius_github_common import (
    canonical_json,
    kw,
    require_map,
    require_positive_integer,
    require_string,
)

_REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
_HEX = re.compile(r"^[0-9a-f]+$")


@dataclass(frozen=True)
class PushResult:
    events: tuple[dict[Any, Any], ...]
    snapshot_version: str
    snapshot_json: bytes


def _boolean(value: Any, name: str) -> bool:
    if not isinstance(value, bool):
        raise ValueError(f"{name} must be a boolean")
    return value


def _git_hash(value: Any, name: str, *, width: int | None = None) -> str:
    digest = require_string(value, name)
    if not _HEX.fullmatch(digest):
        raise ValueError(f"{name} must be lowercase hexadecimal")
    if width is None and len(digest) not in {40, 64}:
        raise ValueError(f"{name} must contain 40 or 64 hexadecimal characters")
    if width is not None and len(digest) != width:
        raise ValueError(f"{name} must contain {width} hexadecimal characters")
    return digest


def _before_hash(value: Any, width: int) -> str:
    before = require_string(value, "before")
    if before == "0" * width:
        return before
    return _git_hash(before, "before", width=width)


def _branch(ref: Any) -> str:
    value = require_string(ref, "ref")
    prefix = "refs/heads/"
    if not value.startswith(prefix):
        raise ValueError("push adapter accepts branch refs under refs/heads only")
    branch = value[len(prefix) :]
    invalid = (
        not branch
        or branch.startswith("/")
        or branch.endswith(("/", "."))
        or ".." in branch
        or "//" in branch
        or "@{" in branch
        or branch == "@"
        or any(char.isspace() or ord(char) < 32 or ord(char) == 127 for char in branch)
        or any(char in "~^:?*[\\" for char in branch)
        or any(
            part in {"", ".", ".."}
            or part.startswith(".")
            or part.endswith(".lock")
            for part in branch.split("/")
        )
    )
    if invalid:
        raise ValueError("ref is not a valid branch reference")
    return branch


def _parents(commit: dict[str, Any], width: int) -> list[str]:
    values = commit.get("parents")
    if not isinstance(values, list):
        raise ValueError("commit.parents must be an array")
    return [
        _git_hash(
            require_map(parent, "commit parent").get("sha"),
            "commit parent sha",
            width=width,
        )
        for parent in values
    ]


def push_events(
    payload: dict[str, Any],
    commit_object: dict[str, Any],
    *,
    workspace: str,
    expected_repository: str,
    delivery_id: str,
    previous_version: str | None,
    process_id: str | None,
) -> PushResult:
    repository = require_map(payload.get("repository"), "repository")
    full_name = require_string(repository.get("full_name"), "repository.full_name")
    if not _REPOSITORY.fullmatch(full_name):
        raise ValueError("repository.full_name is not owner/repository")
    if full_name != expected_repository:
        raise ValueError(
            f"webhook repository {full_name!r} does not match {expected_repository!r}"
        )

    branch = _branch(payload.get("ref"))
    created = _boolean(payload.get("created"), "created")
    deleted = _boolean(payload.get("deleted"), "deleted")
    forced = _boolean(payload.get("forced"), "forced")
    if deleted:
        raise ValueError("branch deletion is not a Git commit resource version")

    after = _git_hash(payload.get("after"), "after")
    width = len(after)
    if after == "0" * width:
        raise ValueError("after cannot be the zero object ID")
    before = _before_hash(payload.get("before"), width)
    zero = "0" * width
    if created and forced:
        raise ValueError("a newly created branch cannot also be a force push")
    if created and before != zero:
        raise ValueError("created branch push must have a zero before object ID")
    if not created and before == zero:
        raise ValueError("non-created branch push cannot have a zero before object ID")
    if created and previous_version is not None:
        raise ValueError("created branch cannot advance an existing Ignatius resource")

    commit_sha = _git_hash(commit_object.get("sha"), "commit.sha", width=width)
    if commit_sha != after:
        raise ValueError("enriched commit SHA does not match push after SHA")
    tree = require_map(commit_object.get("tree"), "commit.tree")
    tree_sha = _git_hash(tree.get("sha"), "commit.tree.sha", width=width)
    parents = _parents(commit_object, width)

    if previous_version is not None:
        _git_hash(previous_version, "previous version", width=width)
    if process_id is not None:
        require_string(process_id, "process ID")

    action = "created" if created else "force-updated" if forced else "updated"
    resource_id = f"github/{full_name}/{payload['ref']}"
    object_format = "sha1" if width == 40 else "sha256"
    snapshot = {
        "repository_id": require_positive_integer(repository.get("id"), "repository.id"),
        "repository_node_id": require_string(
            repository.get("node_id"), "repository.node_id"
        ),
        "repository_full_name": full_name,
        "ref": payload["ref"],
        "branch": branch,
        "before": before,
        "after": after,
        "created": created,
        "forced": forced,
        "commit": {
            "sha": commit_sha,
            "tree": tree_sha,
            "parents": parents,
        },
    }
    snapshot_json = canonical_json(snapshot)
    snapshot_version = f"sha256:{hashlib.sha256(snapshot_json).hexdigest()}"
    metadata = {
        kw("provider/event-id"): delivery_id,
        kw("provider/event-kind"): kw("github/push"),
        kw("provider/event-action"): kw(action),
        kw("github/repository-id"): snapshot["repository_id"],
        kw("github/repository-node-id"): snapshot["repository_node_id"],
        kw("github/repository"): full_name,
        kw("github/before"): before,
        kw("github/after"): after,
        kw("github/created"): created,
        kw("github/forced"): forced,
        kw("git/tree"): tree_sha,
        kw("git/parents"): parents,
        kw("github/snapshot-version"): snapshot_version,
    }
    event: dict[Any, Any] = {
        kw("action"): kw("resource/register"),
        kw("workspace/id"): workspace,
        kw("resource/id"): resource_id,
        kw("resource/kind"): kw("git/commit"),
        kw("resource/provider"): kw("github"),
        kw("resource/version"): commit_sha,
        kw("resource/previous-version"): previous_version,
        kw("resource/parent-versions"): parents,
        kw("resource/locator"): {
            kw("github/repository"): full_name,
            kw("git/ref"): payload["ref"],
            kw("git/tree"): tree_sha,
        },
        kw("resource/digest-algorithm"): kw(f"git/{object_format}"),
        kw("resource/digest"): commit_sha,
        kw("resource/metadata"): metadata,
    }
    if process_id is not None:
        event[kw("process/id")] = process_id
    return PushResult((event,), snapshot_version, snapshot_json)
