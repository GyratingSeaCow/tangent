# SPDX-License-Identifier: AGPL-3.0-or-later
"""Auto-file: after transcription, file the capture into the best EXISTING folder.

Spec (2026-09-30 ask-my-notes doc, queued item #3): the server picks the best
matching existing folder for a finished transcript. Confident -> file it and
announce over sync (the client card shows "Auto-filed to <folder> . Undo");
not confident -> do NOTHING, silently. Folders are never created here.

Classification is deliberately dependency-free (the Ask arc's "no
embeddings/vector DB in v1" decision): TF-IDF cosine similarity between the
new transcript and one bag-of-words document per live folder (folder name,
weighted, plus the text already filed there). Confidence follows the voice-
matching precedent (``diarization.VOICE_ACCEPT``/``VOICE_MARGIN``): the best
folder must clear an absolute floor AND beat the runner-up by a margin, plus
share a minimum number of distinct terms with the transcript — one
coincidental word must never file a capture.
"""

from __future__ import annotations

import math
import re
import sqlite3
import time
from collections import Counter

from app.logging_config import get_logger

log = get_logger(__name__)

#: app_settings key for the server-side auto-file toggle. The toggle gates a
#: SERVER trigger (job_queue's post-transcription hook), so it persists
#: server-side — not in a client's storage (summarizer_worker.SETTINGS_KEY
#: precedent). Unlike summaries, auto-file costs nothing to run, so it
#: defaults ON: an absent row means enabled.
SETTINGS_KEY = "auto_file_enabled"

#: Minimum cosine similarity the best folder must reach. Below it the match
#: is a guess, and the spec says a guess does nothing.
ACCEPT = 0.22

#: How far the best folder must sit above the runner-up. Two folders that
#: both plausibly fit means the server does not know — file nothing.
MARGIN = 0.08

#: Distinct content terms the transcript must share with the winning folder.
MIN_SHARED_TERMS = 3

#: The folder NAME is the user's own label for what belongs inside — worth
#: more than any single filed transcript's vocabulary.
NAME_WEIGHT = 3

#: Per-item and per-folder text budgets. Folder profiles are rebuilt on every
#: trigger (single-user scale), so the cost is bounded, not cached.
ITEM_CHARS = 2000
FOLDER_ITEMS = 25

#: Same stop list as the Ask retrieval endpoint (app.api.ask.STOP_WORDS),
#: duplicated here so a service never imports from the API layer.
STOP_WORDS = frozenset({
    "a", "an", "and", "are", "at", "be", "did", "do", "does", "for", "from",
    "how", "i", "in", "is", "it", "my", "of", "on", "or", "the", "to", "was",
    "what", "when", "where", "which", "who", "why", "with",
})


# --- toggle -------------------------------------------------------------------


def auto_file_enabled(db: sqlite3.Connection) -> bool:
    """The persisted auto-file toggle. Defaults to ON (no install, no cost —
    the confidence gates below are the real safety net)."""
    row = db.execute(
        "SELECT value FROM app_settings WHERE key = ?", (SETTINGS_KEY,)
    ).fetchone()
    return row is None or row[0] == "1"


def set_auto_file_enabled(db: sqlite3.Connection, enabled: bool) -> None:
    db.execute(
        "INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)",
        (SETTINGS_KEY, "1" if enabled else "0"),
    )
    db.commit()


def _tokens(text: str) -> list[str]:
    return [
        term for term in re.findall(r"[\w]+", text.lower(), flags=re.UNICODE)
        if term not in STOP_WORDS and len(term) > 1
    ]


def folder_profiles(db: sqlite3.Connection) -> dict[str, Counter[str]]:
    """One term-frequency document per live folder: its name (weighted) plus
    the text of what is already filed there (recent dumps' titles and
    transcripts, notebook titles, todo texts)."""
    profiles: dict[str, Counter[str]] = {}
    for folder in db.execute(
        "SELECT id, name FROM folders WHERE deleted_at IS NULL"
    ):
        counts: Counter[str] = Counter()
        for _ in range(NAME_WEIGHT):
            counts.update(_tokens(folder["name"]))
        for row in db.execute(
            "SELECT title, transcript FROM dumps "
            "WHERE folder_id = ? AND deleted_at IS NULL "
            "ORDER BY created_at DESC LIMIT ?",
            (folder["id"], FOLDER_ITEMS),
        ):
            counts.update(_tokens(row["title"] or ""))
            counts.update(_tokens((row["transcript"] or "")[:ITEM_CHARS]))
        for row in db.execute(
            "SELECT title FROM notebooks "
            "WHERE folder_id = ? AND deleted_at IS NULL LIMIT ?",
            (folder["id"], FOLDER_ITEMS),
        ):
            counts.update(_tokens(row["title"] or ""))
        for row in db.execute(
            "SELECT text FROM todos "
            "WHERE folder_id = ? AND deleted_at IS NULL LIMIT ?",
            (folder["id"], FOLDER_ITEMS),
        ):
            counts.update(_tokens((row["text"] or "")[:ITEM_CHARS]))
        profiles[folder["id"]] = counts
    return profiles


def _tfidf(counts: Counter[str], idf: dict[str, float]) -> dict[str, float]:
    return {
        term: (1.0 + math.log(tf)) * idf.get(term, 0.0)
        for term, tf in counts.items()
        if tf > 0
    }


def _cosine(a: dict[str, float], b: dict[str, float]) -> float:
    if not a or not b:
        return 0.0
    dot = sum(weight * b[term] for term, weight in a.items() if term in b)
    if dot == 0.0:
        return 0.0
    norm_a = math.sqrt(sum(w * w for w in a.values()))
    norm_b = math.sqrt(sum(w * w for w in b.values()))
    if norm_a == 0.0 or norm_b == 0.0:
        return 0.0
    return dot / (norm_a * norm_b)


def classify(
    transcript_text: str, profiles: dict[str, Counter[str]]
) -> tuple[str, float] | None:
    """The one folder this text confidently belongs in, or None.

    None is the SPEC'D outcome for every unsure case: no folders, an empty
    transcript, a best score under ACCEPT, a runner-up within MARGIN, or
    too few shared terms.
    """
    if not profiles:
        return None
    query = Counter(_tokens(transcript_text))
    if not query:
        return None
    # Smoothed IDF over the folder corpus: a term every folder contains says
    # nothing about which folder fits.
    n_docs = len(profiles)
    df: Counter[str] = Counter()
    for counts in profiles.values():
        df.update(set(counts))
    idf = {term: math.log(1.0 + n_docs / count) for term, count in df.items()}
    default_idf = math.log(1.0 + n_docs)
    query_vec = {
        term: (1.0 + math.log(tf)) * idf.get(term, default_idf)
        for term, tf in query.items()
    }
    scored: list[tuple[float, str]] = []
    for folder_id, counts in profiles.items():
        scored.append((_cosine(query_vec, _tfidf(counts, idf)), folder_id))
    scored.sort(reverse=True)
    best_score, best_id = scored[0]
    runner_up = scored[1][0] if len(scored) > 1 else 0.0
    shared = len(set(query) & set(profiles[best_id]))
    if (
        best_score < ACCEPT
        or best_score - runner_up < MARGIN
        or shared < MIN_SHARED_TERMS
    ):
        log.info(
            "auto_file.unsure",
            best_folder=best_id,
            best=round(best_score, 3),
            runner_up=round(runner_up, 3),
            shared=shared,
        )
        return None
    return best_id, best_score


def maybe_auto_file(db: sqlite3.Connection, dump_id: str) -> str | None:
    """File one freshly transcribed dump, or do nothing. Returns the folder id
    it was filed into, or None.

    Gates: the toggle must be enabled (summaries precedent: the gate lives in
    the service the trigger calls, not in job_queue), and the dump must
    exist, be live, carry a transcript, and be UNFILED — a filing the user
    (or an earlier trigger) already chose is never second-guessed. On a
    confident match the filing, the auto-file markers and the change_log
    entry announcing them commit in the SAME transaction (summarizer_worker's
    persist rule), so no device is ever told about a filing the server does
    not hold.
    """
    if not auto_file_enabled(db):
        return None
    row = db.execute(
        "SELECT transcript, title, folder_id, deleted_at FROM dumps WHERE id = ?",
        (dump_id,),
    ).fetchone()
    if row is None or row["deleted_at"] is not None:
        return None
    if row["folder_id"] is not None:
        return None
    transcript = (row["transcript"] or "").strip()
    if not transcript:
        return None
    profiles = folder_profiles(db)
    verdict = classify(
        f"{row['title'] or ''}\n{transcript}", profiles
    )
    if verdict is None:
        return None
    folder_id, score = verdict
    now = int(time.time())
    try:
        db.execute(
            "UPDATE dumps SET folder_id = ?, auto_filed_at = ?, "
            "auto_file_prev_folder_id = NULL, updated_at = ? WHERE id = ?",
            (folder_id, now, now, dump_id),
        )
        from app.api.dumps import _publish_dump_change  # noqa: PLC0415

        _publish_dump_change(db, dump_id, None)
        db.commit()
    except Exception:
        db.rollback()
        log.exception("auto_file.persist_failed", dump_id=dump_id)
        return None
    log.info(
        "auto_file.filed",
        dump_id=dump_id,
        folder_id=folder_id,
        score=round(score, 3),
    )
    return folder_id
