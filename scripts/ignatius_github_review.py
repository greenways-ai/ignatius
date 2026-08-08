"""Retain exact GitHub pull-request review snapshots without granting authority."""

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
_REVIEW_ACTIONS = frozenset({"submitted", "edited", "dismissed"})
_REVIEW_STATES = frozenset(
    {"approved", "changes_requested", "commented", "dismissed"}
)
_AUTHOR_ASSOCIATIONS = frozenset(
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


@dataclass(frozen=True)
class PullRequestReviewResult:
    events: tuple[dict[Any, Any], ...]
    snapshot_version: str
    snapshot_json: bytes


def _boolean(value: Any, name: str) -> bool:
    if not isinstance(value, bool):
        raise ValueError(f"{name} must be a boolean")
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


def _identity(value: Any, name: str) -> dict[str, Any]:
    identity = require_map(value, name)
    return {
        "id": require_positive_integer(identity.get("id"), f"{name}.id"),
        "node_id": require_string(identity.get("node_id"), f"{name}.node_id"),
        "login": require_string(identity.get("login"), f"{name}.login"),
    }


def _body(value: Any, name: str) -> str | None:
    if value is None or isinstance(value, str):
        return value
    raise ValueError(f"{name} must be a string or null")


def _review_state(action: str, value: Any) -> str:
    state = require_string(value, "review.state")
    if state not in _REVIEW_STATES:
        raise ValueError(f"unsupported pull-request review state {state!r}")
    if action == "dismissed":
        if state != "dismissed":
            raise ValueError("dismissed review event requires state=dismissed")
    elif state == "dismissed":
        raise ValueError(f"{action} review event cannot have state=dismissed")
    return state


def review_events(
    payload: dict[str, Any],
    *,
    workspace: str,
    expected_repository: str,
    delivery_id: str,
    candidate_root: str,
    origin_root: str,
    previous_version: str | None,
) -> PullRequestReviewResult:
    action = require_string(payload.get("action"), "action")
    if action not in _REVIEW_ACTIONS:
        raise ValueError(f"pull-request-review does not accept action={action!r}")
    if action == "submitted" and previous_version is not None:
        raise ValueError("submitted review must be recorded as an initial version")
    if action != "submitted" and previous_version is None:
        raise ValueError(f"{action} review requires the exact previous version")
    if previous_version is not None and not _SNAPSHOT_VERSION.fullmatch(
        previous_version
    ):
        raise ValueError(
            "previous review version must be sha256:<64 lowercase hex characters>"
        )

    repository = _repository(payload.get("repository"), "repository")
    if repository["full_name"] != expected_repository:
        raise ValueError(
            f"webhook repository {repository['full_name']!r} does not match "
            f"{expected_repository!r}"
        )

    pull = require_map(payload.get("pull_request"), "pull_request")
    number = require_positive_integer(pull.get("number"), "pull_request.number")
    envelope_number = payload.get("number")
    if envelope_number is not None:
        if require_positive_integer(envelope_number, "number") != number:
            raise ValueError("payload number does not match pull_request.number")

    pull_state = require_string(pull.get("state"), "pull_request.state")
    if pull_state not in {"open", "closed"}:
        raise ValueError("pull_request.state must be open or closed")
    pull_draft = _boolean(pull.get("draft"), "pull_request.draft")
    pull_merged = _boolean(pull.get("merged"), "pull_request.merged")
    if pull_state == "open" and pull_merged:
        raise ValueError("open pull request cannot be merged")
    if pull_merged and pull_state != "closed":
        raise ValueError("merged pull request must be closed")

    candidate_root = _canonical_root(candidate_root, "candidate root")
    origin_root = _canonical_root(origin_root, "origin root")
    head = require_map(pull.get("head"), "pull_request.head")
    base = require_map(pull.get("base"), "pull_request.base")
    head_repository = _repository(head.get("repo"), "pull_request.head.repo")
    base_repository = _repository(base.get("repo"), "pull_request.base.repo")
    if base_repository["full_name"] != expected_repository:
        raise ValueError("pull request base repository does not match webhook repository")
    if base_repository["id"] != repository["id"]:
        raise ValueError("pull request base repository ID does not match webhook repository")

    head_sha = _git_hash(head.get("sha"), "pull_request.head.sha")
    base_sha = _git_hash(base.get("sha"), "pull_request.base.sha", width=len(head_sha))
    head_ref = _ref(head.get("ref"), "pull_request.head.ref")
    base_ref = _ref(base.get("ref"), "pull_request.base.ref")

    review = require_map(payload.get("review"), "review")
    review_id = require_positive_integer(review.get("id"), "review.id")
    review_node_id = require_string(review.get("node_id"), "review.node_id")
    review_author = _identity(review.get("user"), "review.user")
    actor = _identity(payload.get("sender"), "sender")
    if action in {"submitted", "edited"} and actor["id"] != review_author["id"]:
        raise ValueError(f"{action} review sender must be the review author")

    review_state = _review_state(action, review.get("state"))
    review_commit_sha = _git_hash(
        review.get("commit_id"), "review.commit_id", width=len(head_sha)
    )
    submitted_at = _timestamp(review.get("submitted_at"), "review.submitted_at")
    association = require_string(
        review.get("author_association"), "review.author_association"
    )
    if association not in _AUTHOR_ASSOCIATIONS:
        raise ValueError(f"unsupported review author association {association!r}")
    body = _body(review.get("body"), "review.body")

    snapshot = {
        "repository": repository,
        "pull_request": {
            "id": require_positive_integer(pull.get("id"), "pull_request.id"),
            "node_id": require_string(pull.get("node_id"), "pull_request.node_id"),
            "number": number,
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
            "author": review_author,
            "body": body,
            "state": review_state,
            "commit_id": review_commit_sha,
            "submitted_at": submitted_at,
            "author_association": association,
        },
        "actor": actor,
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
    resource_id = (
        f"github/{expected_repository}/pulls/{number}/reviews/{review_id}"
    )
    metadata = {
        kw("provider/event-id"): delivery_id,
        kw("provider/event-kind"): kw("github/pull-request-review"),
        kw("provider/event-action"): kw(action),
        kw("github/repository-id"): repository["id"],
        kw("github/repository-node-id"): repository["node_id"],
        kw("github/repository"): expected_repository,
        kw("github/pull-request-id"): snapshot["pull_request"]["id"],
        kw("github/pull-request-node-id"): snapshot["pull_request"]["node_id"],
        kw("github/pull-request-number"): number,
        kw("github/pull-request-state"): kw(pull_state),
        kw("github/pull-request-draft"): pull_draft,
        kw("github/pull-request-merged"): pull_merged,
        kw("github/pull-request-head-ref"): head_ref,
        kw("github/pull-request-head-sha"): head_sha,
        kw("github/pull-request-base-ref"): base_ref,
        kw("github/pull-request-base-sha"): base_sha,
        kw("github/review-id"): review_id,
        kw("github/review-node-id"): review_node_id,
        kw("github/review-author"): review_author["login"],
        kw("github/review-author-id"): review_author["id"],
        kw("github/review-author-node-id"): review_author["node_id"],
        kw("github/review-author-association"): association,
        kw("github/review-state"): kw(review_state),
        kw("github/review-commit-sha"): review_commit_sha,
        kw("github/review-current-head"): review_commit_sha == head_sha,
        kw("github/review-submitted-at"): submitted_at,
        kw("github/review-body-present"): body is not None and body != "",
        kw("github/review-actor"): actor["login"],
        kw("github/review-actor-id"): actor["id"],
        kw("github/review-actor-node-id"): actor["node_id"],
        kw("ignatius/candidate-root"): candidate_root,
        kw("ignatius/proposal-origin-root"): origin_root,
        kw("ignatius/proposal-ref-name"): f"proposal/{candidate_root}",
        kw("github/snapshot-format"): kw("json/canonical-v1"),
        kw("github/snapshot-kind"): kw("pull-request-review-v1"),
    }
    resource = {
        kw("action"): kw("resource/register"),
        kw("workspace/id"): workspace,
        kw("resource/id"): resource_id,
        kw("resource/kind"): kw("github/pull-request-review-snapshot"),
        kw("resource/provider"): kw("github"),
        kw("resource/version"): snapshot_version,
        kw("resource/previous-version"): previous_version,
        kw("resource/parent-versions"): (
            [] if previous_version is None else [previous_version]
        ),
        kw("resource/locator"): {
            kw("github/repository"): expected_repository,
            kw("github/pull-request-number"): number,
            kw("github/review-id"): review_id,
        },
        kw("resource/digest-algorithm"): kw("sha256"),
        kw("resource/digest"): digest,
        kw("resource/size"): len(snapshot_json),
        kw("resource/metadata"): metadata,
    }
    return PullRequestReviewResult((resource,), snapshot_version, snapshot_json)
