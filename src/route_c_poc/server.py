"""Ephemeral ASGI entrypoint used only by the isolated port smoke."""

from __future__ import annotations

import os

from .contracts import create_lease
from .egress import EgressRouter, create_egress_app


_lease, _capability = create_lease(os.getpid(), "route-c-poc")
app = create_egress_app(
    EgressRouter(_lease, _capability),
    os.environ.get("ROUTE_C_POC_UPSTREAM", "https://example.invalid/v1/responses"),
)
