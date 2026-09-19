# SPDX-License-Identifier: AGPL-3.0-or-later
"""Startup backfill: pre-sync recordings must enter the change feed.

72 real recordings existed before dump sync; none were in change_log, so a
peer pulling from seq 0 would never learn they exist. init_db backfills
exactly the missing ones and reconciles audio_kept with the files actually
on disk (the upload route historically never set the flag).
"""

import sqlite3
import time
from pathlib import Path

from app.db import init_db


def _connect(data_dir: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    return conn


def _insert_dump(conn, dump_id, title="Old recording", audio_kept=0):
    now = int(time.time())
    conn.execute(
        "INSERT INTO dumps (id, client_id, created_at, updated_at, mode, "
        "duration_seconds, title, transcript, audio_kept) "
        "VALUES (?, 'single-user', ?, ?, 'brain_dump', 5, ?, NULL, ?)",
        (dump_id, now, now, title, audio_kept),
    )


class TestBackfill:
    def test_pre_sync_dumps_are_backfilled_into_feed(self, temp_data_dir):
        init_db(str(temp_data_dir))
        conn = _connect(temp_data_dir)
        try:
            _insert_dump(conn, "dump-old-0001", "Made before sync existed")
            conn.commit()
        finally:
            conn.close()

        # Second startup finds the orphan and publishes it.
        init_db(str(temp_data_dir))

        conn = _connect(temp_data_dir)
        try:
            feed = conn.execute(
                "SELECT * FROM change_log WHERE entity_type = 'dump'"
            ).fetchall()
        finally:
            conn.close()
        assert len(feed) == 1
        assert feed[0]["entity_id"] == "dump-old-0001"
        assert feed[0]["op"] == "upsert"
        assert feed[0]["device_id"] == "server"
        assert '"Made before sync existed"' in feed[0]["payload"]

    def test_backfill_is_idempotent(self, temp_data_dir):
        init_db(str(temp_data_dir))
        conn = _connect(temp_data_dir)
        try:
            _insert_dump(conn, "dump-old-0002")
            conn.commit()
        finally:
            conn.close()

        init_db(str(temp_data_dir))
        init_db(str(temp_data_dir))  # again — must add nothing

        conn = _connect(temp_data_dir)
        try:
            n = conn.execute(
                "SELECT COUNT(*) FROM change_log WHERE entity_id = 'dump-old-0002'"
            ).fetchone()[0]
        finally:
            conn.close()
        assert n == 1

    def test_deleted_dumps_are_not_backfilled(self, temp_data_dir):
        init_db(str(temp_data_dir))
        conn = _connect(temp_data_dir)
        try:
            _insert_dump(conn, "dump-old-0003")
            conn.execute(
                "UPDATE dumps SET deleted_at = ? WHERE id = 'dump-old-0003'",
                (int(time.time()),),
            )
            conn.commit()
        finally:
            conn.close()

        init_db(str(temp_data_dir))

        conn = _connect(temp_data_dir)
        try:
            n = conn.execute(
                "SELECT COUNT(*) FROM change_log WHERE entity_id = 'dump-old-0003'"
            ).fetchone()[0]
        finally:
            conn.close()
        assert n == 0


class TestAudioKeptReconciliation:
    def test_flag_promoted_when_file_on_disk(self, temp_data_dir):
        init_db(str(temp_data_dir))
        conn = _connect(temp_data_dir)
        try:
            _insert_dump(conn, "dump-old-0004", audio_kept=0)
            conn.commit()
        finally:
            conn.close()

        audio = Path(temp_data_dir) / "audio"
        audio.mkdir(exist_ok=True)
        (audio / "dump-old-0004.opus").write_bytes(b"OggS fake audio")

        init_db(str(temp_data_dir))

        conn = _connect(temp_data_dir)
        try:
            row = conn.execute(
                "SELECT audio_kept FROM dumps WHERE id = 'dump-old-0004'"
            ).fetchone()
            payload = conn.execute(
                "SELECT payload FROM change_log WHERE entity_id = 'dump-old-0004'"
            ).fetchone()[0]
        finally:
            conn.close()
        assert row["audio_kept"] == 1
        # Reconciliation runs BEFORE backfill: the published payload
        # already tells peers the audio is downloadable.
        assert '"audio_kept": true' in payload

    def test_flag_never_cleared_by_missing_file(self, temp_data_dir):
        init_db(str(temp_data_dir))
        conn = _connect(temp_data_dir)
        try:
            _insert_dump(conn, "dump-old-0005", audio_kept=1)
            conn.commit()
        finally:
            conn.close()

        init_db(str(temp_data_dir))  # no audio dir contents at all

        conn = _connect(temp_data_dir)
        try:
            row = conn.execute(
                "SELECT audio_kept FROM dumps WHERE id = 'dump-old-0005'"
            ).fetchone()
        finally:
            conn.close()
        assert row["audio_kept"] == 1
