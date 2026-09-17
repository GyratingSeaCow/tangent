# SPDX-License-Identifier: AGPL-3.0-or-later
"""Focused tests for transcription queue concurrency behavior."""

import sqlite3

import pytest

from app.services.job_queue import RequestIdConflict, enqueue_job


class _Cursor:
    def __init__(self, row):
        self._row = row

    def fetchone(self):
        return self._row


class _RacingConnection:
    """Expose no winner initially, then simulate one winning the unique race."""

    def __init__(self, winner):
        self.winner = winner
        self.insert_attempted = False
        self.rolled_back = False

    def execute(self, sql, _params=()):
        if sql.lstrip().startswith("SELECT"):
            return _Cursor(self.winner if self.insert_attempted else None)
        if sql.lstrip().startswith("INSERT"):
            self.insert_attempted = True
            raise sqlite3.IntegrityError("UNIQUE constraint failed: jobs.request_id")
        raise AssertionError(f"unexpected SQL: {sql}")

    def rollback(self):
        self.rolled_back = True

    def commit(self):
        raise AssertionError("loser must not commit")


def test_enqueue_job_unique_race_returns_matching_winner():
    db = _RacingConnection(
        {"id": "winner-job", "dump_id": "dump-a", "model": "large-v3"}
    )

    result = enqueue_job(db, "dump-a", "large-v3", "request-race-001")

    assert result == ("winner-job", False)
    assert db.rolled_back is True


@pytest.mark.parametrize(
    "winner",
    [
        {"id": "winner-job", "dump_id": "dump-b", "model": "large-v3"},
        {"id": "winner-job", "dump_id": "dump-a", "model": "small"},
    ],
)
def test_enqueue_job_unique_race_rejects_mismatched_winner(winner):
    db = _RacingConnection(winner)

    with pytest.raises(RequestIdConflict):
        enqueue_job(db, "dump-a", "large-v3", "request-race-002")

    assert db.rolled_back is True
