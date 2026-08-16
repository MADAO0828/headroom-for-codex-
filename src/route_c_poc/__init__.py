"""Route C isolation contracts.

This package is an in-process PoC only. It does not own production ports or
Codex++ lifecycle state.
"""

from .contracts import (
    INTERNAL_HEADER_PREFIXES,
    RouteLease,
    build_internal_headers,
    create_lease,
    strip_internal_headers,
    validate_upstream_url,
)
from .egress import EgressOutcome, EgressRouter, create_egress_app

__all__ = [
    "EgressOutcome",
    "EgressRouter",
    "INTERNAL_HEADER_PREFIXES",
    "RouteLease",
    "build_internal_headers",
    "create_egress_app",
    "create_lease",
    "strip_internal_headers",
    "validate_upstream_url",
]
