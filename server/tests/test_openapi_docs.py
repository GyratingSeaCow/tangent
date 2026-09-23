# SPDX-License-Identifier: AGPL-3.0-or-later
"""The OpenAPI schema IS the public API documentation.

The README points self-hosters and automation builders (n8n,
Home-Assistant, curl) at /docs. That promise only holds if every
endpoint actually describes itself and the schema never leaks
anything secret-shaped. These tests pin both.
"""

import json
import re

from fastapi.testclient import TestClient

from app.main import create_app

METHODS = {"get", "post", "put", "patch", "delete"}


def _spec() -> dict:
    app = create_app()
    with TestClient(app) as client:
        resp = client.get("/openapi.json")
    assert resp.status_code == 200
    return resp.json()


def test_docs_ui_is_served() -> None:
    """/docs must answer: the README sends people there."""
    app = create_app()
    with TestClient(app) as client:
        resp = client.get("/docs")
    assert resp.status_code == 200
    assert "swagger" in resp.text.lower()


def test_every_endpoint_has_a_description() -> None:
    """Every operation must carry real prose, not just a summary.

    The description is what /docs renders under the endpoint name; an
    empty one reads as an undocumented API to the person we sent there.
    """
    missing = []
    for path, ops in _spec()["paths"].items():
        for method, op in ops.items():
            if method not in METHODS:
                continue
            if not (op.get("description") or "").strip():
                missing.append(f"{method.upper()} {path}")
    assert not missing, f"endpoints missing descriptions: {missing}"


def test_schema_carries_no_secret_shaped_strings() -> None:
    """The schema is served unauthenticated; nothing in it may look
    like a live credential. Field NAMES like 'token' are fine — the
    pairing API is about tokens — but example VALUES must not be."""
    text = json.dumps(_spec())
    for pattern in (
        r"Bearer [A-Za-z0-9_\-]{16,}",
        r'"example": ?"[A-Za-z0-9]{32,}"',
    ):
        hits = re.findall(pattern, text)
        assert not hits, f"secret-shaped string in schema: {pattern} -> {hits}"
