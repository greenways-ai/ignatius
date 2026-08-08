"""Retain exact GitHub pull-request lifecycle snapshots without granting authority."""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from datetime import datetime
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
_ROOT = re.compile(r"^[0-9a-f]{64}$")
_SNAPSHOT_VERSION = re.compile(r"^sha256:[0-9a-f]{64}$")
_LIFECYCLE_ACTIONS = frozenset(
    {"edited", "converted_to_draft", "closed", "reopened"}
)


@dataclass(frozen=True)
class PullRequestLifecycleResult:
    events: tuple[dict[Any, Any], ...]
    snapshot_version: str
    snapshot_json: bytes


def _boolean(value: Any, name: str) -> bool:
    if not isinstance(value, bool):
        raise ValueError(f"{name} must be a boolean")
    return value


def _nonnegative_integer(value: Any, name: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ValueError(f"{name} must be a non-negative integer")
    return value


def _timestamp(value: Any, name: str) -> str:
    text = require_string(value, name)
    if not text.endswith("Z"):
        raise ValueError(f"{name} must be an ISO 8601 UTC timestamp ending in Z")
    try:
        datetime.fromisoformat(text[:-1] + "+00:00")
    except ValueError as error:
        raise ValueError(f"{name} must be an ISO 8601 UTC timestamp") from error
    return text


def _optional_timestamp(value: Any, name: str) -> str | None:
    if value is None:
        return None
    return _timestamp(value, name)


def _git_hash(value: Any, name: str, *, width: int | None = None) -> str:
    digest = require_string(value, name)
    if not _HEX.fullmatch(digest):
        raise ValueError(f"{name} must be lowercase hexadecimal")
    if width is None and len(digest) not in {40, 64}:
        raise ValueError(f"{name} must contain 40 or 64 hexadecimal characters")
    if width is not None and len(digest) != width:
        raise ValueError(f"{name} must contain {width} hexadecimal characters")
    return digest


def _optional_git_hash(value: Any, name: str, *, width: int) -> str | None:
    if value is None:
        return None
    return _git_hash(value, name, width=width)


def _canonical_root(value: Any, name: str) -> str:
    root = require_string(value, name)
    if not _ROOT.fullmatch(root):
        raise ValueError(f"{name} must contain 64 lowercase hexadecimal characters")
    return root


def _repository(value: Any, name: str) -> dict[str, Any]:
    repository = require_map(value, name)
    full_name = require_string(repository.get("full_name"), f"{name}.full_name")
    if not _REPOSITORY.fullmatch(full_name):
        raise ValueError(f"{name}.full_name is not owner/repository")
    return {
        "id": require_positive_integer(repository.get("id"), f"{name}.id"),
        "node_id": require_string(repository.get("node_id"), f"{name}.node_id"),
        "full_name": full_name,
    }


def _ref(value: Any, name: str) -> str:
    ref = require_string(value, name)
    if ref.startswith("/") or ref.endswith("/") or "//" in ref or ".." in ref:
        raise ValueError(f"{name} is not a valid branch name")
    if any(char.isspace() or char in "~^:?*[\\" for char in ref):
        raise ValueError(f"{name} is not a valid branch name")
    return ref


def _state_fields(
    pull: dict[str, Any],
    action: str,
    *,
    object_id_width: int,
) -> dict[str, Any]:
    state = require_string(pull.get("state"), "pull_request.state")
    if state not in {"open", "closed"}:
        raise ValueError("pull_request.state must be open or closed")
    draft = _boolean(pull.get("draft"), "pull_request.draft")
    merged = _boolean(pull.get("merged"), "pull_request.merged")
    closed_at = _optional_timestamp(
        pull.get("closed_at"), "pull_request.closed_at"
    )
    merged_at = _optional_timestamp(
        pull.get("merged_at"), "pull_request.merged_at"
    )
    merge_commit_sha = _optional_git_hash(
        pull.get("merge_commit_sha"),
        "pull_request.merge_commit_sha",
        width=object_id_width,
    )

    if state == "open":
        if closed_at is not None:
            raise ValueError("open pull request must not have closed_at")
        if merged:
            raise ValueError("open pull request cannot be merged")
        if merged_at is not None:
            raise ValueError("open pull request must not have merged_at")
    else:
        if closed_at is None:
            raise ValueError("closed pull request must have closed_at")
        if merged and merged_at is None:
            raise ValueError("merged pull request must have merged_at")
        if not merged and merged_at is not None:
            raise ValueError("unmerged pull request must not have merged_at")

    if action == "converted_to_draft" and (state != "open" or not draft):
        raise ValueError(
            "converted_to_draft requires an open draft pull request"
        )
    if action == "closed" and state != "closed":
        raise ValueError("closed lifecycle event requires state=closed")
    if action == "reopened" and (state != "open" or merged):
        raise ValueError("reopened lifecycle event requires an open unmerged pull request")

    return {
        "state": state,
        "draft": draft,
        "merged": merged,
        "closed_at": closed_at,
        "merged_at": merged_at,
        "merge_commit_sha": merge_commit_sha,
    }


def lifecycle_events(
    payload: dict[str, Any],
    *,
    workspace: str,
    expected_repository: str,
    delivery_id: str,
    candidate_root: str,
    origin_root: str,
    previous_version: str,
) -> PullRequestLifecycleResult:
    action = require_string(payload.get("action"), "action")
    if action not in _LIFECYCLE_ACTIONS:
        raise ValueError(
            f"pull-request-lifecycle does not accept action={action!r}"
        )
    if not _SNAPSHOT_VERSION.fullmatch(previous_version):
        raise ValueError(
            "previous pull-request version must be sha256:<64 lowercase hex characters>"
        )

    repository = _repository(payload.get("repository"), "repository")
    if repository["full_name"] != expected_repository:
        raise ValueError(
            f"webhook repository {repository['full_name']!r} does not match "
            f"{expected_repository!r}"
        )

    number = require_positive_integer(payload.get("number"), "number")
    pull = require_map(payload.get("pull_request"), "pull_request")
    pull_number = require_positive_integer(
        pull.get("number"), "pull_request.number"
    )
    if pull_number != number:
        raise ValueError("payload number does not match pull_request.number")

    candidate_root = _canonical_root(candidate_root, "candidate root")
    origin_root = _canonical_root(origin_root, "origin root")
    author = require_map(pull.get("user"), "pull_request.user")
    head = require_map(pull.get("head"), "pull_request.head")
    base = require_map(pull.get("base"), "pull_request.base")
    head_repository = _repository(head.get("repo"), "pull_request.head.repo")
    base_repository = _repository(base.get("repo"), "pull_request.base.repo")
    if base_repository["full_name"] != expected_repository:
        raise ValueError("pull request base repository does not match webhook repository")
    if base_repository["id"] != repository["id"]:
        raise ValueError("pull request base repository ID does not match webhook repository")

    head_sha = _git_hash(head.get("sha"), "pull_request.head.sha")
    base_sha = _git_hash(
        base.get("sha"), "pull_request.base.sha", width=len(head_sha)
    )
    head_ref = _ref(head.get("ref"), "pull_request.head.ref")
    base_ref = _ref(base.get("ref"), "pull_request.base.ref")
    head_resource_id = (
        f"github/{head_repository['full_name']}/refs/heads/{head_ref}"
    )
    state = _state_fields(pull, action, object_id_width=len(head_sha))

    snapshot = {
        "repository": repository,
        "pull_request": {
            "id": require_positive_integer(pull.get("id"), "pull_request.id"),
            "node_id": require_string(
                pull.get("node_id"), "pull_request.node_id"
            ),
            "number": pull_number,
            "state": state["state"],
            "locked": _boolean(pull.get("locked"), "pull_request.locked"),
            "title": require_string(pull.get("title"), "pull_request.title"),
            "body": pull.get("body") if isinstance(pull.get("body"), str) else "",
            "author_login": require_string(
                author.get("login"), "pull_request.user.login"
            ),
            "draft": state["draft"],
            "merged": state["merged"],
            "created_at": _timestamp(
                pull.get("created_at"), "pull_request.created_at"
            ),
            "updated_at": _timestamp(
                pull.get("updated_at"), "pull_request.updated_at"
            ),
            "closed_at": state["closed_at"],
            "merged_at": state["merged_at"],
            "merge_commit_sha": state["merge_commit_sha"],
            "head": {
                "repository": head_repository,
                "ref": head_ref,
                "sha": head_sha,
                "resource_id": head_resource_id,
            },
            "base": {
                "repository": base_repository,
                "ref": base_ref,
                "sha": base_sha,
            },
            "mergeable": pull.get("mergeable")
            if isinstance(pull.get("mergeable"), bool)
            else None,
            "rebaseable": pull.get("rebaseable")
            if isinstance(pull.get("rebaseable"), bool)
            else None,
            "commits": _nonnegative_integer(
                pull.get("commits", 0), "pull_request.commits"
            ),
            "additions": _nonnegative_integer(
                pull.get("additions", 0), "pull_request.additions"
            ),
            "deletions": _nonnegative_integer(
                pull.get("deletions", 0), "pull_request.deletions"
            ),
            "changed_files": _nonnegative_integer(
                pull.get("changed_files", 0), "pull_request.changed_files"
            ),
        },
        "proposal": {
            "workspace_id": workspace,
            "candidate_root": candidate_root,
            "origin_root": origin_root,
        },
        "lifecycle": {"action": action},
    }
    snapshot_json = canonical_json(snapshot)
    digest = hashlib.sha256(snapshot_json).hexdigest()
    snapshot_version = f"sha256:{digest}"
    resource_id = f"github/{expected_repository}/pulls/{number}"
    metadata = {
        kw("provider/event-id"): delivery_id,
        kw("provider/event-kind"): kw("github/pull-request"),
        kw("provider/event-action"): kw(action),
        kw("github/repository-id"): repository["id"],
        kw("github/repository-node-id"): repository["node_id"],
        kw("github/repository"): expected_repository,
        kw("github/pull-request-id"): snapshot["pull_request"]["id"],
        kw("github/pull-request-node-id"): snapshot["pull_request"]["node_id"],
        kw("github/pull-request-number"): number,
        kw("github/pull-request-author"): snapshot["pull_request"]["author_login"],
        kw("github/pull-request-state"): kw(state["state"]),
        kw("github/pull-request-draft"): state["draft"],
        kw("github/pull-request-merged"): state["merged"],
        kw("github/pull-request-closed-at"): state["closed_at"],
        kw("github/pull-request-merged-at"): state["merged_at"],
        kw("github/pull-request-merge-commit-sha"): state["merge_commit_sha"],
        kw("github/pull-request-head-ref"): head_ref,
        kw("github/pull-request-head-sha"): head_sha,
        kw("github/pull-request-head-resource-id"): head_resource_id,
        kw("github/pull-request-base-ref"): base_ref,
        kw("github/pull-request-base-sha"): base_sha,
        kw("ignatius/candidate-root"): candidate_root,
        kw("ignatius/proposal-origin-root"): origin_root,
        kw("ignatius/proposal-ref-name"): f"proposal/{candidate_root}",
        kw("github/snapshot-format"): kw("json/canonical-v1"),
        kw("github/snapshot-kind"): kw("pull-request-lifecycle-v1"),
    }
    resource = {
        kw("action"): kw("resource/register"),
        kw("workspace/id"): workspace,
        kw("resource/id"): resource_id,
        kw("resource/kind"): kw("github/pull-request-snapshot"),
        kw("resource/provider"): kw("github"),
        kw("resource/version"): snapshot_version,
        kw("resource/previous-version"): previous_version,
        kw("resource/parent-versions"): [previous_version],
        kw("resource/locator"): {
            kw("github/repository"): expected_repository,
            kw("github/pull-request-number"): number,
        },
        kw("resource/digest-algorithm"): kw("sha256"),
        kw("resource/digest"): digest,
        kw("resource/size"): len(snapshot_json),
        kw("resource/metadata"): metadata,
    }
    return PullRequestLifecycleResult((resource,), snapshot_version, snapshot_json)
