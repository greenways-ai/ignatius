"""Completed GitHub check runs mapped to exact evidence and checkpoints."""

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
_SNAPSHOT_VERSION = re.compile(r"^sha256:[0-9a-f]{64}$")
_CONCLUSIONS = frozenset(
    {
        "action_required",
        "cancelled",
        "failure",
        "neutral",
        "skipped",
        "stale",
        "startup_failure",
        "success",
        "timed_out",
    }
)


@dataclass(frozen=True)
class CheckResult:
    events: tuple[dict[Any, Any], ...]
    snapshot_version: str
    snapshot_json: bytes


def _git_hash(value: Any, name: str) -> str:
    digest = require_string(value, name)
    if len(digest) not in {40, 64} or not _HEX.fullmatch(digest):
        raise ValueError(f"{name} must be 40 or 64 lowercase hexadecimal characters")
    return digest


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


def _nonnegative_integer(value: Any, name: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ValueError(f"{name} must be a non-negative integer")
    return value


def _reference(workspace: str, resource_id: str, version: str) -> dict[Any, Any]:
    return {
        kw("record/type"): kw("reference/logical"),
        kw("record/version"): 1,
        kw("record/extensions"): {},
        kw("reference/scope-id"): workspace,
        kw("reference/kind"): kw("resource/version"),
        kw("reference/id"): resource_id,
        kw("reference/root"): version,
        kw("reference/metadata"): {},
    }


def completed_check_events(
    payload: dict[str, Any],
    *,
    workspace: str,
    expected_repository: str,
    delivery_id: str,
    work_id: str,
    commit_resource_id: str,
    commit_version: str,
    previous_version: str | None,
) -> CheckResult:
    action = require_string(payload.get("action"), "action")
    if action != "completed":
        raise ValueError(
            f"check-completed requires action=completed, received {action!r}"
        )

    repository = require_map(payload.get("repository"), "repository")
    full_name = require_string(repository.get("full_name"), "repository.full_name")
    if not _REPOSITORY.fullmatch(full_name):
        raise ValueError("repository.full_name is not owner/repository")
    if full_name != expected_repository:
        raise ValueError(
            f"webhook repository {full_name!r} does not match {expected_repository!r}"
        )

    check = require_map(payload.get("check_run"), "check_run")
    status = require_string(check.get("status"), "check_run.status")
    if status != "completed":
        raise ValueError("completed check webhook must contain status=completed")
    conclusion = require_string(check.get("conclusion"), "check_run.conclusion")
    if conclusion not in _CONCLUSIONS:
        raise ValueError(f"unsupported check conclusion: {conclusion}")

    head_sha = _git_hash(check.get("head_sha"), "check_run.head_sha")
    exact_commit_version = _git_hash(commit_version, "commit version")
    if exact_commit_version != head_sha:
        raise ValueError("commit version does not match check_run.head_sha")
    if previous_version is not None and not _SNAPSHOT_VERSION.fullmatch(
        previous_version
    ):
        raise ValueError(
            "previous check version must be sha256:<64 lowercase hex characters>"
        )

    work_id = require_string(work_id, "work ID")
    commit_resource_id = require_string(commit_resource_id, "commit resource ID")
    output = require_map(check.get("output"), "check_run.output")
    suite = require_map(check.get("check_suite"), "check_run.check_suite")
    app = require_map(check.get("app"), "check_run.app")

    snapshot = {
        "repository_id": require_positive_integer(repository.get("id"), "repository.id"),
        "repository_node_id": require_string(
            repository.get("node_id"), "repository.node_id"
        ),
        "repository_full_name": full_name,
        "check_run": {
            "id": require_positive_integer(check.get("id"), "check_run.id"),
            "node_id": require_string(check.get("node_id"), "check_run.node_id"),
            "name": require_string(check.get("name"), "check_run.name"),
            "head_sha": head_sha,
            "status": status,
            "conclusion": conclusion,
            "started_at": _timestamp(check.get("started_at"), "check_run.started_at"),
            "completed_at": _timestamp(
                check.get("completed_at"), "check_run.completed_at"
            ),
            "external_id": _optional_string(
                check.get("external_id"), "check_run.external_id"
            ),
            "suite_id": require_positive_integer(
                suite.get("id"), "check_run.check_suite.id"
            ),
            "app": {
                "id": require_positive_integer(app.get("id"), "check_run.app.id"),
                "slug": require_string(app.get("slug"), "check_run.app.slug"),
            },
            "output": {
                "title": _optional_string(
                    output.get("title"), "check_run.output.title"
                ),
                "summary": _optional_string(
                    output.get("summary"), "check_run.output.summary"
                ),
                "text": _optional_string(
                    output.get("text"), "check_run.output.text"
                ),
                "annotations_count": _nonnegative_integer(
                    output.get("annotations_count", 0),
                    "check_run.output.annotations_count",
                ),
            },
        },
    }
    snapshot_json = canonical_json(snapshot)
    digest = hashlib.sha256(snapshot_json).hexdigest()
    snapshot_version = f"sha256:{digest}"
    check_run_id = snapshot["check_run"]["id"]
    resource_id = f"github/{full_name}/check-runs/{check_run_id}"
    checkpoint_id = f"{resource_id}/checkpoints/{digest}"
    metadata = {
        kw("provider/event-id"): delivery_id,
        kw("provider/event-kind"): kw("github/check-run"),
        kw("provider/event-action"): kw("completed"),
        kw("github/repository-id"): snapshot["repository_id"],
        kw("github/repository-node-id"): snapshot["repository_node_id"],
        kw("github/repository"): full_name,
        kw("github/check-run-id"): check_run_id,
        kw("github/check-run-node-id"): snapshot["check_run"]["node_id"],
        kw("github/check-suite-id"): snapshot["check_run"]["suite_id"],
        kw("github/check-app-id"): snapshot["check_run"]["app"]["id"],
        kw("github/check-app-slug"): snapshot["check_run"]["app"]["slug"],
        kw("github/check-name"): snapshot["check_run"]["name"],
        kw("github/check-head-sha"): head_sha,
        kw("github/check-status"): kw(status),
        kw("github/check-conclusion"): kw(conclusion),
        kw("github/check-started-at"): snapshot["check_run"]["started_at"],
        kw("github/check-completed-at"): snapshot["check_run"]["completed_at"],
        kw("github/check-annotations-count"): snapshot["check_run"]["output"][
            "annotations_count"
        ],
        kw("github/snapshot-format"): kw("json/canonical-v1"),
    }
    resource = {
        kw("action"): kw("resource/register"),
        kw("workspace/id"): workspace,
        kw("resource/id"): resource_id,
        kw("resource/kind"): kw("github/check-run-snapshot"),
        kw("resource/provider"): kw("github"),
        kw("resource/version"): snapshot_version,
        kw("resource/previous-version"): previous_version,
        kw("resource/parent-versions"): (
            [] if previous_version is None else [previous_version]
        ),
        kw("resource/locator"): {
            kw("github/repository"): full_name,
            kw("github/check-run-id"): check_run_id,
            kw("git/commit"): head_sha,
        },
        kw("resource/digest-algorithm"): kw("sha256"),
        kw("resource/digest"): digest,
        kw("resource/size"): len(snapshot_json),
        kw("resource/metadata"): metadata,
        kw("process/id"): work_id,
    }
    check_reference = _reference(workspace, resource_id, snapshot_version)
    commit_reference = _reference(
        workspace, commit_resource_id, exact_commit_version
    )
    checkpoint = {
        kw("action"): kw("work/checkpoint"),
        kw("workspace/id"): workspace,
        kw("work/id"): work_id,
        kw("checkpoint/id"): checkpoint_id,
        kw("checkpoint/step-id"): f"github/check-run/{check_run_id}",
        kw("checkpoint/state-root"): snapshot_version,
        kw("checkpoint/resource-references"): [
            commit_reference,
            check_reference,
        ],
        kw("checkpoint/receipt-root"): snapshot_version,
        kw("checkpoint/metadata"): metadata,
    }
    return CheckResult((resource, checkpoint), snapshot_version, snapshot_json)
