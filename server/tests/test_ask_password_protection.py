# SPDX-License-Identifier: AGPL-3.0-or-later
"""Protected notebook content is absent from server retrieval."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from app.api.ask import retrieve
from app.db import init_db


def test_protected_notebook_typed_and_ink_content_are_not_retrievable(
    temp_data_dir: Path,
) -> None:
    init_db(str(temp_data_dir))
    db = sqlite3.connect(temp_data_dir / "tangent.db")
    db.row_factory = sqlite3.Row
    db.execute(
        "INSERT INTO notebooks "
        "(id, title, doc, ink, created_at, updated_at, password_hash, "
        "password_salt, password_iterations) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            "private",
            "Private",
            json.dumps({"blocks": [{"text": "typed classified orchid"}]}),
            json.dumps({"strokes": []}),
            1,
            1,
            "hash",
            "salt",
            210000,
        ),
    )
    db.execute(
        "INSERT INTO ink_index "
        "(id, notebook_id, line_id, word_text, word_text_lower, bbox_json, "
        "stroke_ids_json, model, indexed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            "word",
            "private",
            "line",
            "handwritten classified orchid",
            "handwritten classified orchid",
            "[]",
            "[]",
            "test",
            1,
        ),
    )
    db.commit()

    assert retrieve(db, "classified orchid") == []
    db.close()
