# SPDX-License-Identifier: AGPL-3.0-or-later
"""Canonical custom vocabulary storage and prompt helpers."""

from __future__ import annotations

import re
import sqlite3
from collections.abc import Iterable
from typing import Any

SETTINGS_KEY = "custom_vocabulary"
MAX_TERM_CHARS = 64
MAX_TERMS = 200
HOTWORD_TOKEN_BUDGET = 223


class VocabularyValidationError(ValueError):
    """A user-authored vocabulary violates the wire contract."""


def normalize_vocabulary(text: str | None) -> list[str]:
    """Split, trim, and case-insensitively de-duplicate, preserving first spelling."""
    terms: list[str] = []
    seen: set[str] = set()
    for raw in re.split(r"[\n,]", text or ""):
        term = raw.strip()
        if not term:
            continue
        if len(term) > MAX_TERM_CHARS:
            raise VocabularyValidationError("vocabulary term too long")
        folded = term.casefold()
        if folded not in seen:
            seen.add(folded)
            terms.append(term)
    if len(terms) > MAX_TERMS:
        raise VocabularyValidationError("too many vocabulary terms")
    return terms


def canonical_text(terms: Iterable[str]) -> str:
    return ", ".join(terms)


def hotwords_for(terms: Iterable[str]) -> str | None:
    text = canonical_text(terms)
    return text or None


def load_terms(db: sqlite3.Connection) -> list[str]:
    row = db.execute(
        "SELECT value FROM app_settings WHERE key = ?", (SETTINGS_KEY,)
    ).fetchone()
    return [] if row is None else normalize_vocabulary(str(row[0]))


def load_hotwords(db: sqlite3.Connection) -> str | None:
    return hotwords_for(load_terms(db))


def set_vocabulary(db: sqlite3.Connection, text: str | None) -> list[str]:
    terms = normalize_vocabulary(text)
    canonical = canonical_text(terms)
    if canonical:
        db.execute(
            "INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)",
            (SETTINGS_KEY, canonical),
        )
    else:
        db.execute("DELETE FROM app_settings WHERE key = ?", (SETTINGS_KEY,))
    db.commit()
    return terms


def token_estimate(text: str, tokenizer: Any = None) -> int:
    """Use the already-loaded Whisper tokenizer, falling back without model I/O."""
    if not text:
        return 0
    if tokenizer is not None:
        try:
            return len(tokenizer.encode(text))
        except Exception:
            pass
    return len(text) // 4


def summary_suffix(terms: Iterable[str]) -> str:
    text = canonical_text(terms)
    if not text:
        return ""
    return (
        "\n\nPreferred spellings for names and terms that may appear in the\n"
        f"transcript: {text}. Use these spellings exactly."
    )
