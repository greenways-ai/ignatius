"""Shared deterministic encoding and webhook verification for GitHub adapters."""

from __future__ import annotations

import hashlib
import hmac
import json
from dataclasses import dataclass
from typing import Any, Iterable


@dataclass(frozen=True)
class Keyword:
    name: str


def kw(name: str) -> Keyword:
    value = name[1:] if name.startswith(":") else name
    if not value or any(char.isspace() for char in value):
        raise ValueError("invalid EDN keyword")
    return Keyword(value)


def edn(value: Any) -> str:
    if isinstance(value, Keyword):
        return f":{value.name}"
    if value is None:
        return "nil"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    if isinstance(value, (list, tuple)):
        return "[" + " ".join(edn(item) for item in value) + "]"
    if isinstance(value, dict):
        items = sorted(value.items(), key=lambda item: edn(item[0]))
        return "{" + " ".join(f"{edn(k)} {edn(v)}" for k, v in items) + "}"
    raise TypeError(f"unsupported EDN value: {type(value).__name__}")


def _unique_object(pairs: Iterable[tuple[str, Any]]) -> dict[str, Any]:
    output: dict[str, Any] = {}
    for key, value in pairs:
        if key in output:
            raise ValueError(f"duplicate JSON key: {key}")
        output[key] = value
    return output


def parse_json(body: bytes) -> dict[str, Any]:
    value = json.loads(body, object_pairs_hook=_unique_object)
    return require_map(value, "payload")


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def verify_signature(body: bytes, signature: str, secret: str) -> None:
    prefix = "sha256="
    supplied = signature[len(prefix) :] if signature.startswith(prefix) else ""
    if len(supplied) != 64 or any(c not in "0123456789abcdefABCDEF" for c in supplied):
        raise ValueError("GitHub signature must be sha256=<64 hex characters>")
    expected = hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, supplied.lower()):
        raise ValueError("GitHub webhook signature mismatch")


def require_map(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be an object")
    return value


def require_string(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{name} must be a non-empty string")
    return value


def require_positive_integer(value: Any, name: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise ValueError(f"{name} must be a positive integer")
    return value
