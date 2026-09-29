# Voice Matching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A speaker Jeff has named once on any recording is named automatically on every later recording, from a server-side voice book with per-name Forget in Settings.

**Architecture:** pyannote 4.x already returns one 256-dim centroid per diarized speaker; the job runner stores them on the dump (server-private). A device rename that arrives through `/v1/sync/push` folds the renamed speaker's centroid into `voice_book[name]` (running mean). A new transcription with an empty name map is matched against the book (cosine ≥ `VOICE_ACCEPT`, margin ≥ `VOICE_MARGIN`, one name per recording) and the resulting map is written as `speaker_names` — the same field the rename feature syncs, so no client rendering changes. Client adds only Settings → Voices (list + per-row Forget) and a `diarization` flag on `ServerInfo`.

**Tech Stack:** Python 3.11 / FastAPI / sqlite3 / pyannote.audio 4.0.7 (server); Flutter 3 / Riverpod / Dio / freezed (client).

Spec: `docs/design/2026-09-29-voice-matching.md` — read it first. Half A (server, Tasks A1–A5) and Half B (client, Tasks B1–B3) touch disjoint files and run in parallel; Task C (calibration) needs A1–A3 deployed and Jeff's ear.

## Global Constraints

- Silent auto-naming (V1); teaching only from device renames, never from the matcher (V2/§Teaching); one shared server book (V3); per-name Forget only, no wipe-all (V3).
- `dumps.speaker_embeddings` and `voice_book` are SERVER-PRIVATE: never in `_dump_payload`, the sync feed, `DumpCreate`, or `SyncChange`.
- Embeddings L2-normalised before storage; similarity = dot product. Stored as JSON lists of floats.
- Constants live in `server/app/services/diarization.py`: `VOICE_ACCEPT = 0.70`, `VOICE_MARGIN = 0.10` — provisional until Task C.
- A stored non-empty `speaker_names` map is never overwritten by the matcher (spec §Matching; name-map N2 rule).
- Voice names are display strings (spaces, unicode, apostrophes). `ENTITY_ID_PATTERN` does NOT apply. Never build a filesystem path from a name.
- Server tests: `C:/Users/Jeff/Documents/ADH2/server/.venv-test/Scripts/python.exe -m pytest -q -p no:cacheprovider` from `server/`. Baseline **636 passed, 3 skipped**.
- Client tests: `flutter test --no-pub` from `client/` with `/c/Users/Jeff/AppData/Local/flutter/bin` on PATH. Baseline **+2669 ~2**. `flutter analyze --no-pub` must stay "No issues found!".
- CRLF files: `server/app/models.py`, `client/lib/models/server_info.dart`, `client/lib/screens/settings/settings_screen.dart` — detect newline per file before multi-line replace.
- After `dart run build_runner build --delete-conflicting-outputs`, `git checkout -- lib/models/dump.freezed.dart lib/models/dump.g.dart` if they show LF-only churn; never commit `client/linux/flutter` / `client/windows/flutter` generated registrants.
- Commit green work BEFORE each sabotage; every sabotage verifies `git diff --stat` non-empty, quotes the failing assertion, restores, confirms `git status` clean.
- Do NOT push, do NOT rebuild docker, never commit `server/.venv-test/`.

---

## File map

| File | Responsibility |
|---|---|
| `server/app/services/voice_book.py` (new) | Pure math + DB helpers: `normalise`, `teach`, `match`, `load_voice_book`, `forget`. No HTTP, no pyannote. |
| `server/app/services/diarization.py` | `_extract_embeddings(annotation) -> dict[str, list[float]]`; `diarize_segments` gains `return_embeddings` path via `diarize_segments_with_embeddings`. Constants. |
| `server/app/services/transcription.py` | `TranscriptionResult.speaker_embeddings: dict[str, list[float]] \| None`. |
| `server/app/services/job_queue.py` | Store embeddings on the dump; run `match` when the stored map is empty; write `speaker_names`; log `voice_match.applied`. |
| `server/app/db.py` | `_migrate_dumps_speaker_embeddings`, `_migrate_voice_book`. |
| `server/app/api/sync.py` | `_apply_dump` → `_teach_from_rename(conn, existing, new_map, embeddings)` after the upsert. |
| `server/app/api/voices.py` (new) | `GET /v1/voices`, `DELETE /v1/voices/{name}`. |
| `server/app/api/server_info.py` + `models.py` | `ServerInfo.diarization: bool`. |
| `server/scripts/voice_calibrate.py` (new) | Task C script. |
| `client/lib/models/server_info.dart` | `diarization` field (default false). |
| `client/lib/services/summaries_client.dart` | `VoiceEntry`, `listVoices()`, `forgetVoice(name)`. |
| `client/lib/screens/settings/voices_section.dart` (new) | The Voices list. |
| `client/lib/screens/settings/settings_screen.dart` | Mount `VoicesSection` after `GoogleTasksSection`. |

---

# Half A — Server

### Task A1: `voice_book.py` — pure teach/match math + schema

**Files:**
- Create: `server/app/services/voice_book.py`
- Modify: `server/app/db.py` (after `_migrate_dumps_speaker_names`, ~L499; call list ~L984)
- Test: `server/tests/test_voice_book.py`

**Interfaces:**
- Produces:
  ```python
  VOICE_DIM = 256
  def normalise(v: Sequence[float]) -> list[float]            # L2 unit vector; zero vector → zeros
  def teach(conn, name: str, embedding: Sequence[float], *, now: str | None = None) -> None
  def load_voice_book(conn) -> list[VoiceEntry]               # VoiceEntry = NamedTuple(name, embedding: list[float], samples: int, updated_at: str)
  def match(embeddings: Mapping[str, Sequence[float]], book: Sequence[VoiceEntry], *, accept: float, margin: float) -> tuple[dict[str, str], list[tuple[str, float, str]]]
      # returns (label→name map, rejected=[(label, best_sim, best_name), ...]); one name per label, one label per name (higher sim wins)
  def forget(conn, name: str) -> bool                          # True if a row was deleted
  ```
- Schema: `voice_book(name TEXT PRIMARY KEY, embedding TEXT NOT NULL, samples INTEGER NOT NULL DEFAULT 1, updated_at TEXT NOT NULL)`; `dumps.speaker_embeddings TEXT` nullable.

- [ ] **Step 1: Write the failing tests**

```python
# server/tests/test_voice_book.py
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Voice book: teach math, matching rules, forget. Pure sqlite, no pyannote."""
from __future__ import annotations

import math
import sqlite3
from pathlib import Path

import pytest

from app.db import init_db
from app.services import voice_book as vb


def _unit(*coords: float) -> list[float]:
    n = math.sqrt(sum(c * c for c in coords))
    return [c / n for c in coords]


@pytest.fixture
def conn(temp_data_dir: Path) -> sqlite3.Connection:
    init_db()
    c = sqlite3.connect(temp_data_dir / "tangent.db")
    c.row_factory = sqlite3.Row
    return c


def test_schema_has_voice_book_and_embeddings_column(conn):
    cols = {r[1] for r in conn.execute("PRAGMA table_info(voice_book)")}
    assert cols == {"name", "embedding", "samples", "updated_at"}
    dump_cols = {r[1] for r in conn.execute("PRAGMA table_info(dumps)")}
    assert "speaker_embeddings" in dump_cols


def test_migration_is_idempotent(temp_data_dir: Path):
    init_db()
    init_db()
    c = sqlite3.connect(temp_data_dir / "tangent.db")
    assert c.execute("SELECT count(*) FROM voice_book").fetchone()[0] == 0


def test_normalise_unit_and_zero():
    assert vb.normalise([3.0, 4.0]) == pytest.approx([0.6, 0.8])
    assert vb.normalise([0.0, 0.0]) == [0.0, 0.0]


def test_teach_first_sample_is_the_embedding_normalised(conn):
    vb.teach(conn, "Jeff", [3.0, 4.0], now="2026-09-29T00:00:00Z")
    row = conn.execute("SELECT * FROM voice_book WHERE name = 'Jeff'").fetchone()
    assert row["samples"] == 1
    assert vb.load_voice_book(conn)[0].embedding == pytest.approx([0.6, 0.8])
    assert row["updated_at"] == "2026-09-29T00:00:00Z"


def test_teach_running_mean_renormalised(conn):
    vb.teach(conn, "Jeff", _unit(1, 0))
    vb.teach(conn, "Jeff", _unit(0, 1))
    entry = vb.load_voice_book(conn)[0]
    assert entry.samples == 2
    assert entry.embedding == pytest.approx(_unit(1, 1))
    vb.teach(conn, "Jeff", _unit(1, 0))
    entry = vb.load_voice_book(conn)[0]
    assert entry.samples == 3
    # mean of (1,0),(0,1),(1,0) = (2/3,1/3) → normalised
    assert entry.embedding == pytest.approx(_unit(2, 1))


def test_teach_is_case_sensitive_and_trims(conn):
    vb.teach(conn, "  Jeff ", _unit(1, 0))
    vb.teach(conn, "jeff", _unit(0, 1))
    names = sorted(e.name for e in vb.load_voice_book(conn))
    assert names == ["Jeff", "jeff"]


def test_teach_rejects_empty_name(conn):
    with pytest.raises(ValueError):
        vb.teach(conn, "   ", _unit(1, 0))


def _book(**names: list[float]) -> list[vb.VoiceEntry]:
    return [vb.VoiceEntry(n, vb.normalise(e), 1, "t") for n, e in names.items()]


def test_match_accepts_above_threshold_with_margin():
    book = _book(Jeff=_unit(1, 0), Tom=_unit(0, 1))
    names, rejected = vb.match(
        {"Speaker 1": _unit(0.95, 0.05), "Speaker 2": _unit(0.1, 0.9)},
        book, accept=0.70, margin=0.10,
    )
    assert names == {"Speaker 1": "Jeff", "Speaker 2": "Tom"}
    assert rejected == []


def test_match_rejects_below_accept():
    book = _book(Jeff=_unit(1, 0))
    names, rejected = vb.match({"Speaker 1": _unit(0.6, 0.8)}, book, accept=0.70, margin=0.10)
    assert names == {}
    assert rejected == [("Speaker 1", pytest.approx(0.6), "Jeff")]


def test_match_rejects_when_margin_too_small():
    book = _book(Jeff=_unit(1, 0.9), Tom=_unit(0.9, 1))
    names, rejected = vb.match({"Speaker 1": _unit(1, 1)}, book, accept=0.70, margin=0.10)
    assert names == {}
    assert rejected[0][0] == "Speaker 1"


def test_match_single_name_book_has_no_margin_penalty():
    book = _book(Jeff=_unit(1, 0))
    names, _ = vb.match({"Speaker 1": _unit(1, 0.1)}, book, accept=0.70, margin=0.10)
    assert names == {"Speaker 1": "Jeff"}


def test_match_one_label_per_name_higher_similarity_wins():
    book = _book(Jeff=_unit(1, 0))
    names, rejected = vb.match(
        {"Speaker 1": _unit(1, 0.3), "Speaker 2": _unit(1, 0.1)},
        book, accept=0.70, margin=0.10,
    )
    assert names == {"Speaker 2": "Jeff"}
    assert [r[0] for r in rejected] == ["Speaker 1"]


def test_match_empty_book_or_no_embeddings():
    assert vb.match({"Speaker 1": _unit(1, 0)}, [], accept=0.7, margin=0.1) == ({}, [])
    assert vb.match({}, _book(Jeff=_unit(1, 0)), accept=0.7, margin=0.1) == ({}, [])


def test_forget_removes_exactly_one_row(conn):
    vb.teach(conn, "Jeff", _unit(1, 0))
    vb.teach(conn, "Tom", _unit(0, 1))
    assert vb.forget(conn, "Tom") is True
    assert vb.forget(conn, "Tom") is False
    assert [e.name for e in vb.load_voice_book(conn)] == ["Jeff"]
```

- [ ] **Step 2: Run to verify failure**

Run: `cd server && .venv-test/Scripts/python.exe -m pytest -q -p no:cacheprovider tests/test_voice_book.py`
Expected: `ModuleNotFoundError: No module named 'app.services.voice_book'`

- [ ] **Step 3: Schema + migrations in `db.py`**

After `_migrate_dumps_speaker_names` add:

```python
def _migrate_dumps_speaker_embeddings(conn: sqlite3.Connection) -> None:
    """Server-private per-speaker centroids from diarization (v1.36.0)."""
    cols = {row[1] for row in conn.execute("PRAGMA table_info(dumps)")}
    if "speaker_embeddings" not in cols:
        conn.execute("ALTER TABLE dumps ADD COLUMN speaker_embeddings TEXT")


def _migrate_voice_book(conn: sqlite3.Connection) -> None:
    """One remembered centroid per display name (v1.36.0)."""
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS voice_book (
            name TEXT PRIMARY KEY,
            embedding TEXT NOT NULL,
            samples INTEGER NOT NULL DEFAULT 1,
            updated_at TEXT NOT NULL
        )
        """
    )
```

In `init_db` after `speaker_name_backfills = _migrate_dumps_speaker_names(conn)` add:

```python
        _migrate_dumps_speaker_embeddings(conn)
        _migrate_voice_book(conn)
```

- [ ] **Step 4: `voice_book.py`**

```python
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The voice book: one remembered centroid per display name.

Pure math + sqlite. No HTTP, no pyannote — the diarization service hands
over ``{label: embedding}``, this module decides who they are.
"""
from __future__ import annotations

import json
import math
import sqlite3
from collections.abc import Mapping, Sequence
from datetime import datetime, timezone
from typing import NamedTuple

VOICE_DIM = 256


class VoiceEntry(NamedTuple):
    name: str
    embedding: list[float]
    samples: int
    updated_at: str


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def normalise(v: Sequence[float]) -> list[float]:
    norm = math.sqrt(sum(float(x) * float(x) for x in v))
    if norm == 0.0:
        return [0.0 for _ in v]
    return [float(x) / norm for x in v]


def _dot(a: Sequence[float], b: Sequence[float]) -> float:
    return sum(float(x) * float(y) for x, y in zip(a, b, strict=True))


def teach(
    conn: sqlite3.Connection,
    name: str,
    embedding: Sequence[float],
    *,
    now: str | None = None,
) -> None:
    """Fold one centroid into ``name``'s running mean (re-normalised)."""
    clean = name.strip()
    if not clean:
        raise ValueError("voice name must not be empty")
    incoming = normalise(embedding)
    stamp = now or _now()
    row = conn.execute(
        "SELECT embedding, samples FROM voice_book WHERE name = ?", (clean,)
    ).fetchone()
    if row is None:
        conn.execute(
            "INSERT INTO voice_book (name, embedding, samples, updated_at) "
            "VALUES (?, ?, 1, ?)",
            (clean, json.dumps(incoming), stamp),
        )
        return
    old = json.loads(row[0])
    n = int(row[1])
    mean = [(o * n + i) / (n + 1) for o, i in zip(old, incoming, strict=True)]
    conn.execute(
        "UPDATE voice_book SET embedding = ?, samples = ?, updated_at = ? "
        "WHERE name = ?",
        (json.dumps(normalise(mean)), n + 1, stamp, clean),
    )


def load_voice_book(conn: sqlite3.Connection) -> list[VoiceEntry]:
    return [
        VoiceEntry(r[0], json.loads(r[1]), int(r[2]), r[3])
        for r in conn.execute(
            "SELECT name, embedding, samples, updated_at FROM voice_book "
            "ORDER BY updated_at DESC, name"
        )
    ]


def forget(conn: sqlite3.Connection, name: str) -> bool:
    cur = conn.execute("DELETE FROM voice_book WHERE name = ?", (name.strip(),))
    return cur.rowcount == 1


def match(
    embeddings: Mapping[str, Sequence[float]],
    book: Sequence[VoiceEntry],
    *,
    accept: float,
    margin: float,
) -> tuple[dict[str, str], list[tuple[str, float, str]]]:
    """Return (label→name, rejected) — see the spec's §Matching.

    A label is named when its best similarity ≥ ``accept`` and beats the
    second-best NAME by ≥ ``margin`` (no penalty with a one-name book).
    Each name goes to at most one label: the higher similarity keeps it,
    the loser is reported as rejected.
    """
    if not embeddings or not book:
        return {}, []
    candidates: list[tuple[float, str, str]] = []  # (sim, label, name)
    rejected: list[tuple[str, float, str]] = []
    for label, emb in embeddings.items():
        e = normalise(emb)
        sims = sorted(
            ((_dot(e, b.embedding), b.name) for b in book), reverse=True
        )
        best, best_name = sims[0]
        second = sims[1][0] if len(sims) > 1 else -1.0
        if best >= accept and (best - second) >= margin:
            candidates.append((best, label, best_name))
        else:
            rejected.append((label, best, best_name))
    names: dict[str, str] = {}
    claimed: set[str] = set()
    for sim, label, name in sorted(candidates, reverse=True):
        if name in claimed:
            rejected.append((label, sim, name))
            continue
        claimed.add(name)
        names[label] = name
    return names, rejected
```

- [ ] **Step 5: Run tests → all pass**

Run: `cd server && .venv-test/Scripts/python.exe -m pytest -q -p no:cacheprovider tests/test_voice_book.py`
Expected: `14 passed`

- [ ] **Step 6: Commit**

```bash
git add server/app/services/voice_book.py server/app/db.py server/tests/test_voice_book.py
git commit -m "feat(server): voice_book table + teach/match/forget math"
```

- [ ] **Step 7: Sabotage** — in `match`, change `(best - second) >= margin` to `True`. `git diff --stat` non-empty; run the file; expect `test_match_rejects_when_margin_too_small` FAIL with `assert {'Speaker 1': ...} == {}`. Quote it, `git checkout -- server/app/services/voice_book.py`, `git status` clean.

---

### Task A2: Diarization returns embeddings; the job runner stores them

**Files:**
- Modify: `server/app/services/diarization.py` (`_extract_turns` ~L122; `diarize_segments` L183–235; add constants near L24)
- Modify: `server/app/services/transcription.py` (`TranscriptionResult` L101; the diarize call ~L249)
- Modify: `server/app/services/job_queue.py` (~L185 the dumps UPDATE)
- Test: `server/tests/test_diarization.py` (append), `server/tests/test_voice_match_job.py` (new, Task A3 extends it)

**Interfaces:**
- Produces:
  ```python
  # diarization.py
  VOICE_ACCEPT = 0.70
  VOICE_MARGIN = 0.10
  def _extract_embeddings(annotation: Any) -> dict[str, list[float]]   # raw label → unit vector; {} for a bare Annotation
  def diarize_segments_with_embeddings(audio_path, segments) -> tuple[list[dict], dict[str, list[float]]]
      # second element keyed by DISPLAY label ('Speaker N'), {} on any failure
  def diarize_segments(audio_path, segments) -> list[dict]             # unchanged wrapper: first element only
  # transcription.py
  TranscriptionResult(..., speaker_embeddings: dict[str, list[float]] | None = None)
  ```
- `dumps.speaker_embeddings` = `json.dumps(result.speaker_embeddings)` or NULL.

- [ ] **Step 1: Failing tests (append to `test_diarization.py`)**

```python
# --------------------------------------------------------------------------
# Embeddings (v1.36.0 voice matching)
# --------------------------------------------------------------------------


class _FakeDiarizeOutput:
    """pyannote 4.x DiarizeOutput: annotation + centroid rows aligned with labels()."""

    def __init__(self, annotation: _FakeAnnotation, embeddings) -> None:
        self.speaker_diarization = annotation
        self.speaker_embeddings = embeddings

    def labels(self):
        return self.speaker_diarization.labels()


def test_extract_embeddings_keys_by_raw_label_and_normalises() -> None:
    ann = _FakeAnnotation([(0.0, 1.0, "SPEAKER_00"), (1.0, 2.0, "SPEAKER_01")])
    ann.labels = lambda: ["SPEAKER_00", "SPEAKER_01"]
    out = _FakeDiarizeOutput(ann, [[3.0, 4.0], [0.0, 2.0]])
    emb = diarization._extract_embeddings(out)
    assert emb["SPEAKER_00"] == pytest.approx([0.6, 0.8])
    assert emb["SPEAKER_01"] == pytest.approx([0.0, 1.0])


def test_extract_embeddings_bare_annotation_is_empty() -> None:
    ann = _FakeAnnotation([(0.0, 1.0, "SPEAKER_00")])
    assert diarization._extract_embeddings(ann) == {}


def test_extract_embeddings_none_rows_is_empty() -> None:
    ann = _FakeAnnotation([(0.0, 1.0, "SPEAKER_00")])
    ann.labels = lambda: ["SPEAKER_00"]
    assert diarization._extract_embeddings(_FakeDiarizeOutput(ann, None)) == {}


def test_diarize_with_embeddings_keys_by_display_label(monkeypatch) -> None:
    monkeypatch.setenv("TANGENT_DIARIZATION", "pyannote")
    monkeypatch.setenv("HF_TOKEN", "hf_fake")
    # SPEAKER_01 speaks first → it becomes 'Speaker 1'
    ann = _FakeAnnotation([(0.0, 1.0, "SPEAKER_01"), (1.0, 2.0, "SPEAKER_00")])
    ann.labels = lambda: ["SPEAKER_00", "SPEAKER_01"]
    out = _FakeDiarizeOutput(ann, [[1.0, 0.0], [0.0, 1.0]])
    monkeypatch.setattr(diarization, "_load_pipeline", lambda: (lambda _w: out))
    monkeypatch.setattr(diarization, "_decode_waveform", lambda path: {})
    segs = [{"start": 0.0, "end": 1.0, "text": "a"}, {"start": 1.0, "end": 2.0, "text": "b"}]
    labelled, emb = diarization.diarize_segments_with_embeddings("x.wav", segs)
    assert [s["speaker"] for s in labelled] == ["Speaker 1", "Speaker 2"]
    assert emb == {"Speaker 1": pytest.approx([0.0, 1.0]), "Speaker 2": pytest.approx([1.0, 0.0])}


def test_diarize_with_embeddings_failure_yields_empty_dict(monkeypatch) -> None:
    monkeypatch.setenv("TANGENT_DIARIZATION", "pyannote")
    monkeypatch.setenv("HF_TOKEN", "hf_fake")

    def explode():
        raise RuntimeError("boom")

    monkeypatch.setattr(diarization, "_load_pipeline", explode)
    segs = [{"start": 0.0, "end": 1.0, "text": "a"}]
    labelled, emb = diarization.diarize_segments_with_embeddings("x.wav", segs)
    assert labelled == segs and emb == {}
```

Note `_FakeAnnotation` needs a `labels()`; add to the existing class:

```python
    def labels(self):
        seen: list[str] = []
        for _s, _e, label in self._turns:
            if label not in seen:
                seen.append(label)
        return sorted(seen)
```

- [ ] **Step 2: Run** `pytest tests/test_diarization.py -q` → expect `AttributeError: module ... has no attribute '_extract_embeddings'`.

- [ ] **Step 3: Implement in `diarization.py`**

Constants after `PYANNOTE_PIPELINE`:

```python
# Voice matching (v1.36.0). Provisional until scripts/voice_calibrate.py
# has been run on Jeff's recordings — see the spec's §Calibration.
VOICE_ACCEPT = 0.70
VOICE_MARGIN = 0.10
```

After `_extract_turns`:

```python
def _extract_embeddings(annotation: Any) -> dict[str, list[float]]:
    """pyannote 4.x ``DiarizeOutput.speaker_embeddings`` rows, keyed by the
    raw label they are aligned with (``labels()`` order). A bare 3.x
    ``Annotation`` has no embeddings → ``{}``. Vectors come back unit-length.
    """
    from app.services.voice_book import normalise  # noqa: PLC0415

    rows = getattr(annotation, "speaker_embeddings", None)
    if rows is None or not hasattr(annotation, "labels"):
        return {}
    labels = list(annotation.labels())
    out: dict[str, list[float]] = {}
    for label, row in zip(labels, rows):  # rows may be shorter: zip stops
        out[str(label)] = normalise([float(x) for x in row])
    return out
```

Rewrite the tail of `diarize_segments` into `diarize_segments_with_embeddings` and keep the old name as a wrapper:

```python
def diarize_segments_with_embeddings(
    audio_path: str, segments: list[dict[str, Any]]
) -> tuple[list[dict[str, Any]], dict[str, list[float]]]:
    """``diarize_segments`` plus ``{'Speaker N': unit vector}``.

    The second element is ``{}`` whenever labelling did not happen or the
    backend gave no embeddings; it never causes a failure on its own.
    """
    if not segments:
        return list(segments), {}
    if not is_diarization_enabled():
        log.debug("diarization.disabled")
        return [{**segment} for segment in segments], {}
    try:
        pipeline = _load_pipeline()
        annotation = pipeline(_decode_waveform(audio_path))
        turns = _extract_turns(annotation)
        raw_embeddings = _extract_embeddings(annotation)
    except ImportError as exc:
        log.warning("diarization.unavailable", reason=str(exc) or "pyannote.audio is not installed", audio=audio_path)
        return [{**segment} for segment in segments], {}
    except Exception as exc:
        log.warning("diarization.failed", error=str(exc), error_type=type(exc).__name__, audio=audio_path)
        return [{**segment} for segment in segments], {}
    if not turns:
        log.warning("diarization.no_turns", audio=audio_path)
        return [{**segment} for segment in segments], {}
    labelled = assign_speakers(segments, turns)
    display = _label_map(turns)
    embeddings = {
        display[raw]: vec for raw, vec in raw_embeddings.items() if raw in display
    }
    log.info("diarization.complete", audio=audio_path, segments=len(labelled),
             speakers=len({s["speaker"] for s in labelled if s["speaker"]}),
             embeddings=len(embeddings))
    return labelled, embeddings


def diarize_segments(audio_path: str, segments: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Segments with speaker labels; see ``diarize_segments_with_embeddings``."""
    return diarize_segments_with_embeddings(audio_path, segments)[0]
```

(Keep the existing comment about feeding a decoded waveform; move it with the call.)

- [ ] **Step 4: `transcription.py`** — add to `TranscriptionResult` a field `speaker_embeddings: dict[str, list[float]] | None = None` (it's a dataclass; add with the default last). Replace the diarize call:

```python
        speaker_embeddings: dict[str, list[float]] | None = None
        try:
            collected, emb = diarize_segments_with_embeddings(audio_path, collected)
            speaker_embeddings = emb or None
        except Exception as exc:
            ...existing warning...
```

and return `TranscriptionResult(text=joined, segments=collected, peaks=peaks, language=info.language, speaker_embeddings=speaker_embeddings)`. Update the import.

- [ ] **Step 5: `job_queue.py`** — the dumps UPDATE at ~L185 gains `speaker_embeddings = ?`:

```python
            embeddings_json = (
                json.dumps(result.speaker_embeddings) if result.speaker_embeddings else None
            )
            db.execute(
                "UPDATE dumps SET transcript = ?, transcript_timings = ?, "
                "timings_version = 1, language = ?, translated = ?, "
                "speaker_embeddings = ?, updated_at = ? "
                "WHERE id = (SELECT dump_id FROM jobs WHERE id = ?)",
                (transcript, timings_json, result.language, int(translate),
                 embeddings_json, _now_ts(), job_id),
            )
```

- [ ] **Step 6: Job test — `server/tests/test_voice_match_job.py`** (find how existing job tests fake `service.transcribe`: `grep -n "monkeypatch.setattr.*transcribe\|_FakeService\|get_transcription_service" tests/test_jobs*.py tests/test_transcription*.py` and copy that fixture shape — the file that stubs the service and runs `process_job`/the runner once).

```python
def test_job_stores_speaker_embeddings(...fixture from the template...):
    # stub transcribe → TranscriptionResult(text="hi", segments=[...], peaks=[], language="en",
    #   speaker_embeddings={"Speaker 1": [1.0, 0.0]})
    # run the job
    row = conn.execute("SELECT speaker_embeddings FROM dumps WHERE id = ?", (dump_id,)).fetchone()
    assert json.loads(row[0]) == {"Speaker 1": [1.0, 0.0]}


def test_job_without_embeddings_stores_null(...):
    # speaker_embeddings=None → column NULL
```

- [ ] **Step 7: Full suite** → expect `636 + 5 + 2 = 643 passed`. Also `grep -n "speaker_embeddings" server/app/api/dumps.py` must return nothing (never in `_dump_payload`).

- [ ] **Step 8: Commit** `feat(server): diarization returns per-speaker centroids; stored server-private on the dump`

- [ ] **Step 9: Sabotage** — in `diarize_segments_with_embeddings` build `embeddings` from `raw_embeddings` without the `display[raw]` remap. Expect `test_diarize_with_embeddings_keys_by_display_label` FAIL with `assert {'SPEAKER_00': ...} == {'Speaker 1': ...}`. Restore.

---

### Task A3: Teach on rename (`_apply_dump`) and match on transcription (job runner)

**Files:**
- Modify: `server/app/api/sync.py` (`_apply_dump` L224–286)
- Modify: `server/app/services/job_queue.py` (after Step A2.5's UPDATE, before `_publish_dump_change`)
- Test: `server/tests/test_voice_teach_sync.py` (new), `server/tests/test_voice_match_job.py` (extend)

**Interfaces:**
- Produces (sync.py): `_teach_from_rename(conn, stored_map: str | None, new_map: str | None, embeddings_json: str | None) -> list[str]` (names taught).
- Produces (job_queue.py): `_auto_name_speakers(db, dump_id: str, embeddings: dict[str, list[float]]) -> dict[str, str]`.

- [ ] **Step 1: Failing tests — `test_voice_teach_sync.py`**

```python
# SPDX-License-Identifier: AGPL-3.0-or-later
"""A device rename teaches the voice book; only changed pairs; never from the matcher."""
from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from fastapi.testclient import TestClient

from app.services import voice_book as vb

DUMP = "dump-teach"


def _push(client: TestClient, token: str, payload: dict):
    return client.post(
        "/v1/sync/push",
        headers={"Authorization": f"Bearer {token}"},
        json={"device_id": "device-aaaa-1", "changes": [
            {"entity_type": "dump", "entity_id": DUMP, "op": "upsert", "payload": payload}
        ]},
    )


def _seed(temp_data_dir: Path, embeddings: dict | None) -> sqlite3.Connection:
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    conn.execute(
        "INSERT INTO dumps (id, client_id, created_at, updated_at, mode, duration_seconds, "
        "title, transcript, speaker_embeddings, audio_kept) VALUES (?, 'c', 1, 1, 'meeting', 10, "
        "'Standup', '## Speaker 1\\nSpeaker 1: hi', ?, 1)",
        (DUMP, json.dumps(embeddings) if embeddings else None),
    )
    conn.commit()
    return conn


def test_rename_teaches_each_named_label(authed_client, temp_data_dir):
    client, token = authed_client
    conn = _seed(temp_data_dir, {"Speaker 1": [1.0, 0.0], "Speaker 2": [0.0, 1.0]})
    r = _push(client, token, {"speaker_names": json.dumps({"Speaker 1": "Jeff", "Speaker 2": "Tom"})})
    assert r.status_code == 200
    book = {e.name: e for e in vb.load_voice_book(conn)}
    assert set(book) == {"Jeff", "Tom"}
    assert book["Jeff"].embedding == [1.0, 0.0] and book["Jeff"].samples == 1


def test_unchanged_pairs_do_not_bump_samples(authed_client, temp_data_dir):
    client, token = authed_client
    conn = _seed(temp_data_dir, {"Speaker 1": [1.0, 0.0], "Speaker 2": [0.0, 1.0]})
    _push(client, token, {"speaker_names": json.dumps({"Speaker 1": "Jeff"})})
    _push(client, token, {"speaker_names": json.dumps({"Speaker 1": "Jeff", "Speaker 2": "Tom"})})
    book = {e.name: e for e in vb.load_voice_book(conn)}
    assert book["Jeff"].samples == 1 and book["Tom"].samples == 1


def test_correction_teaches_new_name_leaves_old_alone(authed_client, temp_data_dir):
    client, token = authed_client
    conn = _seed(temp_data_dir, {"Speaker 1": [1.0, 0.0]})
    vb.teach(conn, "Tom", [0.0, 1.0]); conn.commit()
    _push(client, token, {"speaker_names": json.dumps({"Speaker 1": "Dana"})})
    book = {e.name: e for e in vb.load_voice_book(conn)}
    assert book["Tom"].embedding == [0.0, 1.0] and book["Tom"].samples == 1
    assert book["Dana"].embedding == [1.0, 0.0]


def test_unmapped_or_blank_or_no_embedding_teaches_nothing(authed_client, temp_data_dir):
    client, token = authed_client
    conn = _seed(temp_data_dir, {"Speaker 1": [1.0, 0.0]})
    _push(client, token, {"speaker_names": json.dumps({"Speaker 1": "  ", "Speaker 2": "Ghost"})})
    assert vb.load_voice_book(conn) == []


def test_same_map_resent_teaches_nothing(authed_client, temp_data_dir):
    client, token = authed_client
    conn = _seed(temp_data_dir, {"Speaker 1": [1.0, 0.0]})
    _push(client, token, {"speaker_names": json.dumps({"Speaker 1": "Jeff"})})
    _push(client, token, {"title": "Edited"})            # map absent → preserved, no teach
    _push(client, token, {"speaker_names": json.dumps({"Speaker 1": "Jeff"})})
    assert vb.load_voice_book(conn)[0].samples == 1
```

Extend `test_voice_match_job.py`:

```python
def test_job_auto_names_when_map_empty(...):
    # seed voice_book: Jeff=[1,0]; stub transcribe with speaker_embeddings={"Speaker 1":[1,0.05],"Speaker 2":[0,1]}
    # run job → dumps.speaker_names == {"Speaker 1": "Jeff"}; voice_book Jeff.samples still 1 (matcher never teaches)


def test_job_never_overwrites_existing_map(...):
    # dump pre-seeded with speaker_names={"Speaker 1":"Tom"}; same run → map unchanged == {"Speaker 1":"Tom"}


def test_job_empty_book_leaves_map_null(...):
    # no voice_book rows → speaker_names stays NULL
```

- [ ] **Step 2: Run** → `AttributeError`/assertion failures as expected.

- [ ] **Step 3: `sync.py`** — after the `INSERT … ON CONFLICT` in `_apply_dump`, add:

```python
    if "speaker_names" in p:
        _teach_from_rename(
            conn,
            existing["speaker_names"] if existing is not None else None,
            p["speaker_names"],
            existing["speaker_embeddings"] if existing is not None else None,
        )
```

and the helper (module level, after `_apply_dump`):

```python
def _teach_from_rename(
    conn: sqlite3.Connection,
    stored_map: str | None,
    new_map: str | None,
    embeddings_json: str | None,
) -> list[str]:
    """Spec §Teaching: a device-authored map teaches the voice book for every
    (label → name) pair that is new or whose name changed. Removed pairs,
    blank names and labels without a centroid teach nothing. Returns the
    names taught (for logs/tests)."""
    from app.services.voice_book import teach  # noqa: PLC0415

    if not new_map or not embeddings_json:
        return []
    try:
        new = json.loads(new_map) or {}
        old = json.loads(stored_map) if stored_map else {}
        embeddings = json.loads(embeddings_json) or {}
    except (TypeError, ValueError):
        return []
    taught: list[str] = []
    for label, name in new.items():
        clean = (name or "").strip()
        if not clean or old.get(label) == name or label not in embeddings:
            continue
        teach(conn, clean, embeddings[label])
        taught.append(clean)
    if taught:
        log.info("voice_book.taught", names=taught)
    return taught
```

(`sync.py` already imports `json` and has `log`; confirm with grep.)

- [ ] **Step 4: `job_queue.py`** — after the dumps UPDATE from A2, before the publish block:

```python
            if result.speaker_embeddings:
                _auto_name_speakers(db, job_id, result.speaker_embeddings)
```

and the helper (module level):

```python
def _auto_name_speakers(
    db: sqlite3.Connection, job_id: str, embeddings: dict[str, list[float]]
) -> dict[str, str]:
    """Spec §Matching. Writes ``speaker_names`` ONLY when the stored map is
    empty; never teaches. Returns the map written ({} when nothing was)."""
    from app.services.diarization import VOICE_ACCEPT, VOICE_MARGIN  # noqa: PLC0415
    from app.services.voice_book import load_voice_book, match  # noqa: PLC0415

    row = db.execute(
        "SELECT id, speaker_names FROM dumps WHERE id = (SELECT dump_id FROM jobs WHERE id = ?)",
        (job_id,),
    ).fetchone()
    if row is None:
        return {}
    stored = row["speaker_names"]
    if stored and stored.strip() not in ("", "{}"):
        return {}
    book = load_voice_book(db)
    if not book:
        return {}
    names, rejected = match(embeddings, book, accept=VOICE_ACCEPT, margin=VOICE_MARGIN)
    log.info(
        "voice_match.applied",
        dump_id=row["id"],
        names=names,
        rejected=[(label, round(sim, 3), name) for label, sim, name in rejected],
    )
    if names:
        db.execute(
            "UPDATE dumps SET speaker_names = ? WHERE id = ?",
            (json.dumps(names), row["id"]),
        )
    return names
```

Note the summarizer renders `speaker_names` from the row at summarize time, so a map written here reaches the summary with no further plumbing. `_publish_dump_change` (already called after) carries it to devices.

- [ ] **Step 5: Full suite** → `643 + 5 + 3 = 651 passed`.

- [ ] **Step 6: Commit** `feat(server): renames teach the voice book; new transcriptions auto-name from it`

- [ ] **Step 7: Sabotage ×2** — (a) in `_auto_name_speakers` delete the `if stored …: return {}` guard → `test_job_never_overwrites_existing_map` FAIL `assert {'Speaker 1': 'Jeff'} == {'Speaker 1': 'Tom'}`. (b) add `teach(db, name, embeddings[label])` inside `_auto_name_speakers` after the match → `test_job_auto_names_when_map_empty` FAIL on `samples == 1` (`assert 2 == 1`). Restore each, quote each.

---

### Task A4: `/v1/voices` API + `ServerInfo.diarization`

**Files:**
- Create: `server/app/api/voices.py`
- Modify: `server/app/main.py` (router include — `grep -n "include_router" app/main.py`)
- Modify: `server/app/models.py` (`ServerInfo` L125 — CRLF), `server/app/api/server_info.py` (L46–L70)
- Test: `server/tests/test_voices_api.py`, `server/tests/test_server_info.py` (append)

**Interfaces:**
- `GET /v1/voices` → `200 [{"name": str, "samples": int, "updated_at": str}]` newest first.
- `DELETE /v1/voices/{name}` → `204`; `404 {"detail": "unknown voice"}`.
- `ServerInfo.diarization: bool`.

- [ ] **Step 1: Failing tests**

```python
# server/tests/test_voices_api.py
# SPDX-License-Identifier: AGPL-3.0-or-later
from __future__ import annotations

import sqlite3
from pathlib import Path
from urllib.parse import quote

from app.services import voice_book as vb


def _conn(temp_data_dir: Path) -> sqlite3.Connection:
    c = sqlite3.connect(temp_data_dir / "tangent.db")
    c.row_factory = sqlite3.Row
    return c


def test_list_requires_auth(authed_client):
    client, _ = authed_client
    assert client.get("/v1/voices").status_code == 401


def test_list_shape_newest_first(authed_client, temp_data_dir):
    client, token = authed_client
    c = _conn(temp_data_dir)
    vb.teach(c, "Tom", [0.0, 1.0], now="2026-09-29T01:00:00Z")
    vb.teach(c, "Jeff O'Neil", [1.0, 0.0], now="2026-09-29T02:00:00Z")
    c.commit()
    r = client.get("/v1/voices", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200
    assert r.json() == [
        {"name": "Jeff O'Neil", "samples": 1, "updated_at": "2026-09-29T02:00:00Z"},
        {"name": "Tom", "samples": 1, "updated_at": "2026-09-29T01:00:00Z"},
    ]
    assert "embedding" not in r.text


def test_delete_one_name_with_space_and_unicode(authed_client, temp_data_dir):
    client, token = authed_client
    c = _conn(temp_data_dir)
    vb.teach(c, "Zoë Smith", [1.0, 0.0]); vb.teach(c, "Tom", [0.0, 1.0]); c.commit()
    r = client.delete(f"/v1/voices/{quote('Zoë Smith')}", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 204
    assert [e.name for e in vb.load_voice_book(c)] == ["Tom"]


def test_delete_unknown_404(authed_client):
    client, token = authed_client
    r = client.delete("/v1/voices/Nobody", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 404
```

Append to `test_server_info.py` (copy its existing authed GET pattern):

```python
def test_server_info_reports_diarization_flag(authed_client, monkeypatch):
    client, token = authed_client
    monkeypatch.delenv("TANGENT_DIARIZATION", raising=False)
    assert client.get("/v1/server/info", headers={"Authorization": f"Bearer {token}"}).json()["diarization"] is False
    monkeypatch.setenv("TANGENT_DIARIZATION", "pyannote"); monkeypatch.setenv("HF_TOKEN", "x")
    assert client.get("/v1/server/info", headers={"Authorization": f"Bearer {token}"}).json()["diarization"] is True
```

- [ ] **Step 2: Run** → 404s / KeyError.

- [ ] **Step 3: Implement `voices.py`** (mirror the dependency style of `app/api/google_tasks.py` — `get_db`, `require_auth`; check their exact names with `sed -n '1,30p' app/api/google_tasks.py`):

```python
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Settings → Voices: list remembered voices, forget one at a time."""
from __future__ import annotations

import sqlite3
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import BaseModel

from app.auth import require_auth
from app.db import get_db
from app.services.voice_book import forget, load_voice_book

router = APIRouter(tags=["voices"])


class VoiceOut(BaseModel):
    name: str
    samples: int
    updated_at: str


@router.get("/v1/voices", response_model=list[VoiceOut])
def list_voices(
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _auth: Annotated[None, Depends(require_auth)],
) -> list[VoiceOut]:
    return [VoiceOut(name=e.name, samples=e.samples, updated_at=e.updated_at) for e in load_voice_book(db)]


@router.delete("/v1/voices/{name:path}", status_code=status.HTTP_204_NO_CONTENT)
def forget_voice(
    name: str,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _auth: Annotated[None, Depends(require_auth)],
) -> Response:
    # A display name, never an entity id: looked up, never used as a path.
    if not forget(db, name):
        raise HTTPException(status_code=404, detail="unknown voice")
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
```

Register in `main.py` next to the google_tasks router. `ServerInfo` gains `diarization: bool = False`; `server_info.py` passes `diarization=is_diarization_enabled()` (import from `app.services.diarization`).

- [ ] **Step 4: Full suite** → `651 + 4 + 1 = 656 passed`. Commit `feat(server): /v1/voices list + forget; ServerInfo.diarization`.

- [ ] **Step 5: Sabotage** — change `forget`'s SQL to `DELETE FROM voice_book WHERE name LIKE ?` with `name.strip() + '%'`... simpler: replace `WHERE name = ?` with `WHERE 1=1 OR name = ?`. Expect `test_delete_one_name_with_space_and_unicode` FAIL `assert [] == ['Tom']`. Restore.

---

### Task A5: Calibration script (code only; Task C runs it)

**Files:**
- Create: `server/scripts/voice_calibrate.py`
- Test: `server/tests/test_voice_calibrate.py` (the pure ranking function only)

**Interfaces:**
- `rank_against(reference: list[float], candidates: list[tuple[str, str, list[float]]]) -> list[tuple[float, str, str]]` — `(sim, dump_title, label)` sorted desc. Script body: open `/data/tangent.db`, for every dump with `audio_kept=1` and an audio file, run `diarize_segments_with_embeddings` on the stored segments (`transcript_timings` JSON `segments`), write `speaker_embeddings` if NULL, then take the reference = the centroid of every label currently mapped to `--name` (default `Jeff`) and print the ranking table.

- [ ] **Step 1: Test**

```python
from scripts.voice_calibrate import rank_against

def test_rank_against_sorts_desc_and_keeps_title_label():
    ref = [1.0, 0.0]
    rows = rank_against(ref, [("A", "Speaker 1", [0.0, 1.0]), ("B", "Speaker 2", [1.0, 0.0]), ("C", "Speaker 1", [0.7, 0.7])])
    assert [(round(s, 2), t, l) for s, t, l in rows] == [(1.0, "B", "Speaker 2"), (0.71, "C", "Speaker 1"), (0.0, "A", "Speaker 1")]
```

(add `server/scripts/__init__.py` if needed for import; check `pytest` rootdir/`pythonpath` in `pyproject.toml`.)

- [ ] **Step 2–4:** implement, green, commit `chore(server): voice_calibrate.py for threshold calibration`. Script CLI:

```
python -m scripts.voice_calibrate --name Jeff [--db /data/tangent.db] [--audio-root /data/audio]
```

prints:

```
reference 'Jeff' from 1 recording(s), 1 label(s)
 sim    recording                          label       already named
 0.93   2026-09-28 Standup                 Speaker 1   Jeff
 0.81   2026-09-27 Brain dump              Speaker 1   -
 ...
```

---

# Half B — Client

### Task B1: `ServerInfo.diarization` + `SummariesClient.listVoices/forgetVoice`

**Files:**
- Modify: `client/lib/models/server_info.dart` (CRLF)
- Modify: `client/lib/services/summaries_client.dart` (after `syncGoogleTasksNow` ~L491; models near `GoogleCalendarStatus`)
- Test: `client/test/unit/models/server_info_test.dart` (find existing; else create), `client/test/unit/services/summaries_client_voices_test.dart`

**Interfaces:**
```dart
class VoiceEntry { final String name; final int samples; final DateTime updatedAt; factory VoiceEntry.fromJson(Map<String, dynamic>); }
Future<List<VoiceEntry>> listVoices();          // GET /v1/voices
Future<void> forgetVoice(String name);          // DELETE /v1/voices/<Uri.encodeComponent(name)>; 404 → throws
ServerInfo.diarization: bool                    // json['diarization'] ?? false
```

- [ ] **Step 1: Failing tests** (Dio mocked via `SummariesClient.forTesting(dio:)` with a `Dio` whose `httpClientAdapter` is a fake — copy the pattern from `test/unit/services/summaries_client_test.dart`):

```dart
test('ServerInfo.fromJson defaults diarization to false on an older server', () {
  final info = ServerInfo.fromJson({...minimal fields...});
  expect(info.diarization, isFalse);
  expect(ServerInfo.fromJson({...minimal, 'diarization': true}).diarization, isTrue);
});

test('listVoices decodes list newest-first', () async { ... expect(v.first.name, "Jeff O'Neil"); expect(v.first.samples, 1); });

test('forgetVoice DELETEs the percent-encoded name', () async {
  await client.forgetVoice("Zoë Smith");
  expect(capturedPath, '/v1/voices/Zo%C3%AB%20Smith');
});

test('forgetVoice 404 throws', () async { expect(() => client.forgetVoice('Nobody'), throwsA(anything)); });
```

- [ ] **Step 2–4:** implement; `dart run build_runner build --delete-conflicting-outputs` (server_info is freezed); analyze clean; tests green; commit `feat(client): ServerInfo.diarization; voices list/forget on SummariesClient`.

- [ ] **Step 5: Sabotage** — `forgetVoice` uses the raw name instead of `Uri.encodeComponent` → `expect(capturedPath, '/v1/voices/Zo%C3%AB%20Smith')` fails with `Actual: '/v1/voices/Zoë Smith'`. Restore.

---

### Task B2: `VoicesSection` widget

**Files:**
- Create: `client/lib/screens/settings/voices_section.dart`
- Modify: `client/lib/screens/settings/settings_screen.dart` (~L226, after `const GoogleTasksSection(),` — CRLF)
- Test: `client/test/widget/voices_section_test.dart`

**Interfaces:**
- `class VoicesSection extends ConsumerStatefulWidget` — reads `summariesClientProvider` (from `ai_summaries_section.dart`) and `transcriptionClientProvider` for `getServerInfo()`.
- Keys: `voices-section`, `voices-empty`, `voice-row-<name>`, `voice-forget-<name>`, `voices-forget-confirm`, `voices-forget-cancel`.
- Copy (verbatim from spec): title **Voices**; row subtitle `taught by 1 recording` / `taught by N recordings`; empty `No remembered voices yet. Rename a speaker on a recording and Tangent will recognise them next time.`; dialog `Forget <name>'s voice? Recordings already naming <name> keep their names.` with **Forget** / **Cancel**.
- Hidden entirely (returns `SizedBox.shrink`) when `serverInfo.diarization == false` or the info call fails.

- [ ] **Step 1: Failing widget tests** — fake client as in `google_tasks_section_test.dart`'s `_FakeClient` (extends `SummariesClient`, overrides `listVoices`/`forgetVoice`), fake `TranscriptionClient.getServerInfo` via the provider override used in `ai_summaries_section` tests:

```dart
testWidgets('hidden when diarization is off', ...)          // findsNothing for 'voices-section'
testWidgets('empty state copy', ...)
testWidgets('rows: name + taught-by count, singular/plural', ...)
testWidgets('Forget: dialog copy, confirm → forgetVoice(name) and row gone', ...)
testWidgets('Forget: cancel → nothing called, row stays', ...)
testWidgets('no wipe-all control exists', (tester) async {
  expect(find.textContaining('Forget all'), findsNothing);
  expect(find.byIcon(Icons.delete_sweep), findsNothing);
});
```

- [ ] **Step 2–4:** implement (a `Card` like `GoogleTasksSection`: header row, `FutureBuilder`/state list, `ListTile`s with trailing `IconButton(Icons.delete_outline)`, `showDialog` → `AlertDialog`); mount in `settings_screen.dart`; analyze clean; green; commit `feat(client): Settings → Voices with per-name Forget`.

- [ ] **Step 5: Sabotage** — make cancel call `forgetVoice` too → the cancel test fails `Expected: <0> Actual: <1>`. Restore.

---

### Task B3: Docs + version (done by the integrator after merge, not a worker)

- `CHANGELOG.md` `## 1.36.0` — Added: voice matching (V1–V3 in user words), Settings → Voices; Changed: server `voice_book` table + `dumps.speaker_embeddings` (server-private), `ServerInfo.diarization`, `/v1/voices`.
- README `### Voice` — a paragraph after the calendar one: rename once → recognised next time; Settings → Voices → Forget; requires diarization (`TANGENT_DIARIZATION=pyannote` + `HF_TOKEN`).
- AGENTS.md status paragraph; version bump 7 sites (`client/pubspec.yaml` 1.36.0+49, `server/pyproject.toml`, `server/app/version.py`, `server/docker-compose.yml`, README badges with the new counts).

---

# Task C — Calibration (needs Jeff + deployed server; blocks the tag)

1. Merge A1–A5, Jeff rebuilds the container (`docker compose … up -d --build` in PowerShell — compose hangs from git-bash).
2. `docker exec tangent-server python -m scripts.voice_calibrate --name Jeff` → paste the table to Jeff; he marks which rows are actually him.
3. Compute: `lowest_true`, `highest_impostor`. Set `VOICE_ACCEPT = max(0.70, highest_impostor + 0.05)` rounded up to 0.01; keep `VOICE_MARGIN = 0.10` unless two true-Jeff rows against a second name show margins below it. Record both numbers and the gap in the spec's status line; commit `chore(server): calibrate VOICE_ACCEPT from Jeff's recordings`.
4. Rebuild again; device proof per spec §Device proof (three recordings on the Fold; evidence from the DB + `voice_match.applied` log lines).
5. Tag v1.36.0 → three assets.

---

## Self-review

- **Spec coverage:** V1 silent → A3 writes the map with no client prompt ✓. V2 → `_teach_from_rename` skips unchanged/removed pairs, never touches other names ✓ (test `correction_teaches_new_name_leaves_old_alone`). V3 shared book + per-name Forget, no wipe-all → A1 `forget`, A4 route, B2 widget + "no wipe-all" test ✓. Embedding source → A2 ✓. Data model server-private → A2 Step 7 grep ✓. Teaching only from device → A3 sabotage (b) ✓. Matching rules incl. one-name-per-recording → A1 tests ✓. Stored map never overwritten → A3 test + sabotage (a) ✓. Log line → A3 ✓. Calibration → A5 + C ✓. Settings hidden when diarization off → A4 flag + B2 ✓. API 404/encoding → A4/B1 ✓. Device proof → C ✓.
- **Placeholders:** A2 Step 6 and A3 Step 1's job tests describe the fixture by reference to an existing file because the runner harness varies; the worker must copy the concrete fixture from `tests/test_job*.py` — acceptable, flagged.
- **Type consistency:** `VoiceEntry` (Python NamedTuple) fields `name/embedding/samples/updated_at` used identically in A1, A3, A4, A5; `match` signature identical in A1 and A3; `diarize_segments_with_embeddings` name identical in A2/A5; Dart `VoiceEntry.name/samples/updatedAt` in B1/B2 ✓.
