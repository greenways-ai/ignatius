"""Verified GitHub pull requests mapped to exact snapshots and proposal intents."""

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
_PROPOSAL_ACTIONS = frozenset({"opened", "ready_for_review", "reopened", "synchronize"})


@dataclass(frozen=True)
class PullRequestResult:
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


def _optional_string(value: Any, name: str) -> str | None:
    if value is None:
        return None
    return require_string(value, name)


def _timestamp(value: Any, name: str) -> str:
    text = require_string(value, name)
    if not text.endswith("Z"):
        raise ValueError(f"{name} must be an ISO 8601 UTC timestamp ending in Z")
    try:
        datetime.fromisoformat(text[:-1] + "+00:00")
    except ValueError as error:
        raise ValueError(f"{name} must be an ISO 8601 UTC timestamp") from error
    return text


def _git_hash(value: Any, name: str, *, width: int | None = None) -> str:
    digest = require_string(value, name)
    if not _HEX.fullmatch(digest):
        raise ValueError(f"{name} must be lowercase hexadecimal")
    if width is None and len(digest) not in {40, 64}:
        raise ValueError(f"{name} must contain 40 or 64 hexadecimal characters")
    if width is not None and len(digest) != width:
        raise ValueError(f"{name} must contain {width} hexadecimal characters")
    return digest


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


def proposal_intent(
    workspace: str,
    candidate_root: str,
    origin_root: str,
) -> dict[Any, Any]:
    return {
        kw("record/type"): kw("workspace/ref-update-intent"),
        kw("record/version"): 1,
        kw("record/extensions"): {},
        kw("workspace/id"): workspace,
        kw("ref/scope"): f"workspace/{workspace}",
        kw("ref/name"): f"proposal/{candidate_root}",
        kw("ref/expected-root"): None,
        kw("ref/desired-root"): candidate_root,
        kw("ref/authorization-root"): origin_root,
        kw("ref/policy"): kw("proposal-publication-v1"),
        kw("ref/metadata"): {},
    }


def proposal_events(
    payload: dict[str, Any],
    *,
    workspace: str,
    expected_repository: str,
    delivery_id: str,
    candidate_root: str,
    origin_root: str,
    previous_version: str | None,
) -> PullRequestResult:
    action = require_string(payload.get("action"), "action")
    if action not in _PROPOSAL_ACTIONS:
        raise ValueError(f"pull-request-proposal does not accept action={action!r}")

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
    if require_string(pull.get("state"), "pull_request.state") != "open":
        raise ValueError("proposal pull request must be open")
    if _boolean(pull.get("merged"), "pull_request.merged"):
        raise ValueError("merged pull request is not a new proposal")
    if _boolean(pull.get("draft"), "pull_request.draft"):
        raise ValueError("draft pull request is not ready for proposal publication")

    candidate_root = _canonical_root(candidate_root, "candidate root")
    origin_root = _canonical_root(origin_root, "origin root")
    if previous_version is not None and not _SNAPSHOT_VERSION.fullmatch(
        previous_version
    ):
        raise ValueError(
            "previous pull-request version must be sha256:<64 lowercase hex characters>"
        )

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

    snapshot = {
        "repository": repository,
        "pull_request": {
            "id": require_positive_integer(pull.get("id"), "pull_request.id"),
            "node_id": require_string(
                pull.get("node_id"), "pull_request.node_id"
            ),
            "number": pull_number,
            "state": "open",
            "locked": _boolean(pull.get("locked"), "pull_request.locked"),
            "title": require_string(pull.get("title"), "pull_request.title"),
            "body": pull.get("body") if isinstance(pull.get("body"), str) else "",
            "author_login": require_string(
                author.get("login"), "pull_request.user.login"
            ),
            "draft": False,
            "created_at": _timestamp(
                pull.get("created_at"), "pull_request.created_at"
            ),
            "updated_at": _timestamp(
                pull.get("updated_at"), "pull_request.updated_at"
            ),
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
        kw("github/pull-request-head-ref"): head_ref,
        kw("github/pull-request-head-sha"): head_sha,
        kw("github/pull-request-head-resource-id"): head_resource_id,
        kw("github/pull-request-base-ref"): base_ref,
        kw("github/pull-request-base-sha"): base_sha,
        kw("ignatius/candidate-root"): candidate_root,
        kw("ignatius/proposal-origin-root"): origin_root,
        kw("ignatius/proposal-ref-name"): f"proposal/{candidate_root}",
        kw("github/snapshot-format"): kw("json/canonical-v1"),
    }
    resource = {
        kw("action"): kw("resource/register"),
        kw("workspace/id"): workspace,
        kw("resource/id"): resource_id,
        kw("resource/kind"): kw("github/pull-request-snapshot"),
        kw("resource/provider"): kw("github"),
        kw("resource/version"): snapshot_version,
        kw("resource/previous-version"): previous_version,
        kw("resource/parent-versions"): (
            [] if previous_version is None else [previous_version]
        ),
        kw("resource/locator"): {
            kw("github/repository"): expected_repository,
            kw("github/pull-request-number"): number,
        },
        kw("resource/digest-algorithm"): kw("sha256"),
        kw("resource/digest"): digest,
        kw("resource/size"): len(snapshot_json),
        kw("resource/metadata"): metadata,
    }
    intent = proposal_intent(workspace, candidate_root, origin_root)
    return PullRequestResult((resource, intent), snapshot_version, snapshot_json)
