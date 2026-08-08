"""GitHub issue snapshots mapped onto provider-neutral Ignatius workflow events."""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from typing import Any, Sequence

from ignatius_github_common import (
    canonical_json,
    kw,
    require_map,
    require_positive_integer,
    require_string,
)

_REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


@dataclass(frozen=True)
class IssueResult:
    events: tuple[dict[Any, Any], ...]
    snapshot_version: str
    snapshot_json: bytes


def _labels(issue: dict[str, Any]) -> list[str]:
    labels = issue.get("labels", [])
    if not isinstance(labels, list):
        raise ValueError("issue.labels must be an array")
    names = {
        require_string(require_map(label, "issue label").get("name"), "issue label name")
        for label in labels
    }
    return sorted(names)


def issue_snapshot(payload: dict[str, Any], expected_repository: str) -> dict[str, Any]:
    repository = require_map(payload.get("repository"), "repository")
    issue = require_map(payload.get("issue"), "issue")
    if "pull_request" in issue:
        raise ValueError("pull requests are not GitHub issue work requests")

    full_name = require_string(repository.get("full_name"), "repository.full_name")
    if not _REPOSITORY.fullmatch(full_name):
        raise ValueError("repository.full_name is not owner/repository")
    if full_name != expected_repository:
        raise ValueError(
            f"webhook repository {full_name!r} does not match {expected_repository!r}"
        )

    author = require_map(issue.get("user"), "issue.user")
    state = require_string(issue.get("state"), "issue.state")
    if state != "open":
        raise ValueError("issues.opened payload must contain state=open")

    return {
        "repository_id": require_positive_integer(repository.get("id"), "repository.id"),
        "repository_node_id": require_string(repository.get("node_id"), "repository.node_id"),
        "repository_full_name": full_name,
        "issue_id": require_positive_integer(issue.get("id"), "issue.id"),
        "issue_node_id": require_string(issue.get("node_id"), "issue.node_id"),
        "issue_number": require_positive_integer(issue.get("number"), "issue.number"),
        "title": require_string(issue.get("title"), "issue.title"),
        "body": issue.get("body") if isinstance(issue.get("body"), str) else "",
        "state": state,
        "author_login": require_string(author.get("login"), "issue.user.login"),
        "created_at": require_string(issue.get("created_at"), "issue.created_at"),
        "updated_at": require_string(issue.get("updated_at"), "issue.updated_at"),
        "labels": _labels(issue),
    }


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


def opened_events(
    payload: dict[str, Any],
    *,
    workspace: str,
    expected_repository: str,
    definition_root: str,
    delivery_id: str,
    dependencies: Sequence[str],
    previous_version: str | None,
) -> IssueResult:
    action = require_string(payload.get("action"), "action")
    if action != "opened":
        raise ValueError(f"issue-opened requires action=opened, received {action!r}")

    snapshot = issue_snapshot(payload, expected_repository)
    snapshot_json = canonical_json(snapshot)
    digest = hashlib.sha256(snapshot_json).hexdigest()
    version = f"sha256:{digest}"
    stable_id = (
        f"github/{snapshot['repository_full_name']}/issues/{snapshot['issue_number']}"
    )
    metadata = {
        kw("provider/event-id"): delivery_id,
        kw("provider/event-kind"): kw("github/issues"),
        kw("provider/event-action"): kw("opened"),
        kw("github/repository-id"): snapshot["repository_id"],
        kw("github/repository-node-id"): snapshot["repository_node_id"],
        kw("github/repository"): snapshot["repository_full_name"],
        kw("github/issue-id"): snapshot["issue_id"],
        kw("github/issue-node-id"): snapshot["issue_node_id"],
        kw("github/issue-number"): snapshot["issue_number"],
        kw("github/issue-author"): snapshot["author_login"],
        kw("github/issue-updated-at"): snapshot["updated_at"],
        kw("github/issue-labels"): snapshot["labels"],
        kw("github/snapshot-format"): kw("json/canonical-v1"),
    }
    parents = [] if previous_version is None else [previous_version]
    resource = {
        kw("action"): kw("resource/register"),
        kw("workspace/id"): workspace,
        kw("resource/id"): stable_id,
        kw("resource/kind"): kw("github/issue-snapshot"),
        kw("resource/provider"): kw("github"),
        kw("resource/version"): version,
        kw("resource/previous-version"): previous_version,
        kw("resource/parent-versions"): parents,
        kw("resource/locator"): {
            kw("github/repository"): snapshot["repository_full_name"],
            kw("github/issue-number"): snapshot["issue_number"],
        },
        kw("resource/digest-algorithm"): kw("sha256"),
        kw("resource/digest"): digest,
        kw("resource/size"): len(snapshot_json),
        kw("resource/metadata"): metadata,
    }
    work = {
        kw("action"): kw("work/create"),
        kw("workspace/id"): workspace,
        kw("work/id"): stable_id,
        kw("work/kind"): kw("agent/task"),
        kw("work/title"): snapshot["title"],
        kw("work/definition-root"): definition_root,
        kw("work/dependency-ids"): sorted(set(dependencies)),
        kw("work/input-references"): [_reference(workspace, stable_id, version)],
        kw("work/metadata"): metadata,
    }
    return IssueResult((resource, work), version, snapshot_json)
