"""Small, dependency-light Route C security and lifecycle contracts."""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import ipaddress
import secrets
import time
from typing import Mapping
from urllib.parse import urlsplit
from uuid import uuid4


INTERNAL_HEADER_PREFIXES = (
    "x-headroom-internal-",
    "x-codex-route-",
    "x-route-c-",
)
RESERVED_PORTS = {
    57321,
    57322,
    58321,
    58322,
    18787,
    18788,
    18789,
    18790,
    18887,
    18888,
    18889,
    18890,
}


class RouteContractError(ValueError):
    """Raised when a Route C contract is invalid."""


@dataclass(frozen=True)
class RouteLease:
    """A redacted lease record; the raw capability never belongs in state."""

    owner_pid: int
    owner_start: str
    generation: str
    capability_sha256: str
    heartbeat_at: float
    stale_after: float = 15.0

    def is_live(self, now: float | None = None) -> bool:
        current = time.time() if now is None else now
        return current - self.heartbeat_at <= self.stale_after

    def verify(self, capability: str, now: float | None = None) -> bool:
        digest = sha256(capability.encode("utf-8")).hexdigest()
        return self.is_live(now) and secrets.compare_digest(
            digest, self.capability_sha256
        )


def create_lease(
    owner_pid: int,
    owner_start: str,
    *,
    generation: str | None = None,
    now: float | None = None,
    stale_after: float = 15.0,
) -> tuple[RouteLease, str]:
    """Create a lease and return the raw capability only to the caller."""

    if owner_pid <= 0:
        raise RouteContractError("owner_pid must be positive")
    if not owner_start:
        raise RouteContractError("owner_start is required")
    raw_capability = secrets.token_urlsafe(32)
    lease = RouteLease(
        owner_pid=owner_pid,
        owner_start=owner_start,
        generation=generation or uuid4().hex,
        capability_sha256=sha256(raw_capability.encode("utf-8")).hexdigest(),
        heartbeat_at=time.time() if now is None else now,
        stale_after=stale_after,
    )
    return lease, raw_capability


def build_internal_headers(
    lease: RouteLease, capability: str, *, correlation_id: str | None = None
) -> dict[str, str]:
    """Build headers for internal hops; callers must strip them before egress."""

    if not lease.verify(capability):
        raise RouteContractError("invalid or stale lease capability")
    return {
        "x-route-c-generation": lease.generation,
        "x-route-c-capability": capability,
        "x-route-c-correlation": correlation_id or uuid4().hex,
    }


def strip_internal_headers(headers: Mapping[str, str]) -> dict[str, str]:
    """Remove all Route C/Headroom internal headers case-insensitively."""

    clean: dict[str, str] = {}
    for key, value in headers.items():
        lowered = key.lower()
        if any(lowered.startswith(prefix) for prefix in INTERNAL_HEADER_PREFIXES):
            continue
        clean[key] = value
    return clean


def validate_upstream_url(url: str) -> str:
    """Reject local/reserved upstreams to prevent a Route C self-cycle."""

    parsed = urlsplit(url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise RouteContractError("upstream must be an http(s) URL with a host")
    if parsed.username or parsed.password:
        raise RouteContractError("upstream URL must not contain credentials")
    host = parsed.hostname.lower().rstrip(".")
    if host in {"localhost", "localhost.localdomain"} or host.endswith(".localhost"):
        raise RouteContractError("loopback hostname is forbidden")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        address = None
    if address is not None and (address.is_loopback or address.is_unspecified):
        raise RouteContractError("loopback/unspecified upstream is forbidden")
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    if port in RESERVED_PORTS:
        raise RouteContractError("reserved Route C port is forbidden")
    return url
