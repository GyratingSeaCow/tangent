# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for the /v1/transcription/model(s) endpoints.

Nothing here downloads anything: whisper_models' downloader is injectable
and the "installed" fixtures build the same HuggingFace cache layout
faster-whisper produces. Auth is required on everything.
"""

from __future__ import annotations

import sqlite3
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from app.services import transcription, whisper_models


@pytest.fixture(autouse=True)
def _reset_state():
    whisper_models._reset_state_for_tests()
    transcription.reset_transcription_service()
    yield
    whisper_models._reset_state_for_tests()
    transcription.reset_transcription_service()


@pytest.fixture
def client(temp_data_dir: Path):
    with TestClient(create_app()) as cli:
        token = cli.post("/v1/setup", json={"display_name": "T"}).json()["token"]
        yield cli, {"Authorization": f"Bearer {token}"}, temp_data_dir


def _install_on_disk(data_dir: Path, name: str, size: int = 2048) -> Path:
    """Make ``name`` read as installed: the real HF cache shape + model.bin."""
    repo = data_dir / "models" / f"models--Systran--faster-whisper-{name}"
    snapshot = repo / "snapshots" / "deadbeef"
    snapshot.mkdir(parents=True, exist_ok=True)
    (snapshot / "config.json").write_bytes(b"{}")
    with open(snapshot / "model.bin", "wb") as f:
        f.truncate(size)
    return repo


def _open_db(data_dir: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    return conn


def _setting(data_dir: Path) -> str | None:
    conn = _open_db(data_dir)
    try:
        row = conn.execute(
            "SELECT value FROM app_settings WHERE key = 'whisper_model'"
        ).fetchone()
    finally:
        conn.close()
    return None if row is None else row["value"]


def _wait_for(cond, timeout: float = 10.0) -> bool:
    deadline = time.time() + timeout
    while not cond() and time.time() < deadline:
        time.sleep(0.01)
    return cond()


# ---------------------------------------------------------------------------
# GET /v1/transcription/models — inventory
# ---------------------------------------------------------------------------


class TestInventory:
    def test_lists_every_model_in_accuracy_order_with_active(self, client):
        cli, auth, _ = client
        res = cli.get("/v1/transcription/models", headers=auth)
        assert res.status_code == 200
        body = res.json()
        assert set(body) == {"active", "models"}
        assert body["active"] == "large-v3", "env/default resolution, not a guess"
        assert [m["name"] for m in body["models"]] == [
            "large-v3",
            "medium",
            "small",
            "base",
            "tiny",
        ], "accuracy order — the client renders this list directly"
        for model in body["models"]:
            assert set(model) == {
                "name",
                "installed",
                "size_bytes_on_disk",
                "approx_download_bytes",
            }
            assert model["installed"] is False
            assert model["size_bytes_on_disk"] == 0
            assert model["approx_download_bytes"] > 0

    def test_reports_installed_models_with_measured_size(self, client):
        cli, auth, data_dir = client
        _install_on_disk(data_dir, "small", size=4096)
        body = cli.get("/v1/transcription/models", headers=auth).json()
        rows = {m["name"]: m for m in body["models"]}
        assert rows["small"]["installed"] is True
        assert rows["small"]["size_bytes_on_disk"] >= 4096
        assert rows["medium"]["installed"] is False

    def test_requires_auth(self, client):
        cli, _, _ = client
        assert cli.get("/v1/transcription/models").status_code == 401


# ---------------------------------------------------------------------------
# PUT /v1/transcription/model — selection
# ---------------------------------------------------------------------------


class TestSelect:
    def test_selecting_installed_model_returns_full_state_and_persists(
        self, client
    ):
        cli, auth, data_dir = client
        _install_on_disk(data_dir, "small")

        res = cli.put(
            "/v1/transcription/model", json={"name": "small"}, headers=auth
        )

        assert res.status_code == 200
        body = res.json()
        assert body["active"] == "small"
        assert [m["name"] for m in body["models"]] == [
            "large-v3",
            "medium",
            "small",
            "base",
            "tiny",
        ], "PUT answers with the same body as GET"
        assert _setting(data_dir) == "small", "the choice must survive a restart"
        assert cli.get("/v1/transcription/models", headers=auth).json()["active"] == (
            "small"
        )

    def test_unsupported_name_is_400(self, client):
        cli, auth, data_dir = client
        res = cli.put(
            "/v1/transcription/model", json={"name": "enormous-v9"}, headers=auth
        )
        assert res.status_code == 400
        assert "unsupported" in res.json()["detail"].lower()
        assert _setting(data_dir) is None, "a rejected name must not be persisted"

    def test_not_installed_model_is_409(self, client):
        """The client must install first — mirrors the regenerate contract."""
        cli, auth, data_dir = client
        res = cli.put(
            "/v1/transcription/model", json={"name": "medium"}, headers=auth
        )
        assert res.status_code == 409
        assert "not installed" in res.json()["detail"].lower()
        assert _setting(data_dir) is None, (
            "a refused selection must not be persisted"
        )
        assert cli.get("/v1/transcription/models", headers=auth).json()["active"] == (
            "large-v3"
        ), "the active model must be unchanged after a refused selection"

    def test_successful_selection_invalidates_the_cached_service(
        self, client, monkeypatch
    ):
        """Requirement 7: the NEXT job loads the newly selected model, with
        no container restart — so the cached instance must be dropped."""
        cli, auth, data_dir = client
        _install_on_disk(data_dir, "tiny")
        calls: list[int] = []
        monkeypatch.setattr(
            "app.api.transcription_models.reset_transcription_service",
            lambda: calls.append(1),
        )

        assert (
            cli.put(
                "/v1/transcription/model", json={"name": "tiny"}, headers=auth
            ).status_code
            == 200
        )

        assert calls == [1], "a successful selection must reset the cached service"

    def test_refused_selection_does_not_invalidate_the_cached_service(
        self, client, monkeypatch
    ):
        cli, auth, _ = client
        calls: list[int] = []
        monkeypatch.setattr(
            "app.api.transcription_models.reset_transcription_service",
            lambda: calls.append(1),
        )

        assert (
            cli.put(
                "/v1/transcription/model", json={"name": "medium"}, headers=auth
            ).status_code
            == 409
        )

        assert calls == [], "a rejected selection must leave the live model loaded"

    def test_requires_auth(self, client):
        cli, _, _ = client
        assert (
            cli.put("/v1/transcription/model", json={"name": "tiny"}).status_code == 401
        )


# ---------------------------------------------------------------------------
# POST /v1/transcription/models/{name}/install + progress
# ---------------------------------------------------------------------------


def _fake_downloader(data_dir: Path, size: int = 2048):
    """Build the real HF cache shape inside the install's tmp cache root."""

    def download(name: str, cache_dir: str) -> None:
        snapshot = (
            Path(cache_dir)
            / f"models--Systran--faster-whisper-{name}"
            / "snapshots"
            / "deadbeef"
        )
        snapshot.mkdir(parents=True, exist_ok=True)
        (snapshot / "config.json").write_bytes(b"{}")
        with open(snapshot / "model.bin", "wb") as f:
            f.truncate(size)

    return download


class TestInstall:
    def test_install_202_then_progress_reaches_done_and_model_installed(
        self, client, monkeypatch
    ):
        cli, auth, data_dir = client
        monkeypatch.setattr(
            whisper_models, "default_downloader", _fake_downloader(data_dir)
        )

        res = cli.post("/v1/transcription/models/small/install", headers=auth)

        assert res.status_code == 202
        assert res.json() == {"status": "installing"}
        assert _wait_for(lambda: not whisper_models.install_running())
        prog = cli.get(
            "/v1/transcription/models/install/progress", headers=auth
        ).json()
        assert prog["phase"] == "done"
        assert prog["model"] == "small"
        assert prog["percent"] == 100
        rows = {
            m["name"]: m
            for m in cli.get("/v1/transcription/models", headers=auth).json()["models"]
        }
        assert rows["small"]["installed"] is True

    def test_install_does_not_change_the_active_model(self, client, monkeypatch):
        """Requirement 4: selection stays an explicit SECOND step."""
        cli, auth, data_dir = client
        monkeypatch.setattr(
            whisper_models, "default_downloader", _fake_downloader(data_dir)
        )

        assert (
            cli.post(
                "/v1/transcription/models/tiny/install", headers=auth
            ).status_code
            == 202
        )
        assert _wait_for(lambda: not whisper_models.install_running())

        body = cli.get("/v1/transcription/models", headers=auth).json()
        assert body["active"] == "large-v3", (
            "installing must never change which model transcribes"
        )
        assert _setting(data_dir) is None, "install must not write the selection"

    def test_unsupported_name_is_400(self, client):
        cli, auth, _ = client
        res = cli.post("/v1/transcription/models/enormous-v9/install", headers=auth)
        assert res.status_code == 400
        assert "unsupported" in res.json()["detail"].lower()

    def test_second_install_while_running_is_409(self, client, monkeypatch):
        import threading

        cli, auth, data_dir = client
        release = threading.Event()
        finish = _fake_downloader(data_dir)

        def blocking_downloader(name: str, cache_dir: str) -> None:
            release.wait(timeout=10)
            finish(name, cache_dir)

        monkeypatch.setattr(
            whisper_models, "default_downloader", blocking_downloader
        )
        try:
            assert (
                cli.post(
                    "/v1/transcription/models/small/install", headers=auth
                ).status_code
                == 202
            )
            res = cli.post("/v1/transcription/models/tiny/install", headers=auth)
            assert res.status_code == 409, (
                "409 = attach semantics for the wizard, not an error"
            )
            assert "already running" in res.json()["detail"].lower()
        finally:
            release.set()
        assert _wait_for(lambda: not whisper_models.install_running())

    def test_progress_is_idle_before_any_install(self, client):
        cli, auth, _ = client
        res = cli.get("/v1/transcription/models/install/progress", headers=auth)
        assert res.status_code == 200
        assert res.json() == {
            "phase": "idle",
            "percent": 0,
            "detail": "",
            "model": "",
        }

    def test_progress_mirrors_the_service(self, client):
        cli, auth, _ = client
        whisper_models._set_progress("downloading", 42, "downloading small", "small")
        assert cli.get(
            "/v1/transcription/models/install/progress", headers=auth
        ).json() == {
            "phase": "downloading",
            "percent": 42,
            "detail": "downloading small",
            "model": "small",
        }

    def test_failed_install_surfaces_as_a_failed_phase(self, client, monkeypatch):
        cli, auth, _ = client

        def boom(name: str, cache_dir: str) -> None:
            raise RuntimeError("network unplugged")

        monkeypatch.setattr(whisper_models, "default_downloader", boom)

        assert (
            cli.post(
                "/v1/transcription/models/small/install", headers=auth
            ).status_code
            == 202
        )
        assert _wait_for(lambda: not whisper_models.install_running())
        prog = cli.get(
            "/v1/transcription/models/install/progress", headers=auth
        ).json()
        assert prog["phase"] == "failed"
        assert "network unplugged" in prog["detail"], (
            "the client shows the server's error text with a Retry"
        )
        rows = {
            m["name"]: m
            for m in cli.get("/v1/transcription/models", headers=auth).json()["models"]
        }
        assert rows["small"]["installed"] is False, (
            "a failed install must leave no partial dir"
        )

    def test_install_endpoints_require_auth(self, client):
        cli, _, _ = client
        assert cli.post("/v1/transcription/models/small/install").status_code == 401
        assert cli.get("/v1/transcription/models/install/progress").status_code == 401


# ---------------------------------------------------------------------------
# DELETE /v1/transcription/models/{name}
# ---------------------------------------------------------------------------


class TestDelete:
    def test_deletes_an_installed_non_active_model(self, client):
        cli, auth, data_dir = client
        repo = _install_on_disk(data_dir, "tiny")

        res = cli.delete("/v1/transcription/models/tiny", headers=auth)

        assert res.status_code == 200
        assert res.json() == {"deleted": True}
        assert not repo.exists(), "weights must be gone from disk"
        rows = {
            m["name"]: m
            for m in cli.get("/v1/transcription/models", headers=auth).json()["models"]
        }
        assert rows["tiny"]["installed"] is False
        assert rows["tiny"]["size_bytes_on_disk"] == 0

    def test_deleting_a_model_that_is_not_there_reports_deleted_false(self, client):
        """Idempotent: nothing to remove is not an error (404 is not used)."""
        cli, auth, _ = client
        res = cli.delete("/v1/transcription/models/tiny", headers=auth)
        assert res.status_code == 200
        assert res.json() == {"deleted": False}

    def test_deleting_the_active_model_is_409(self, client):
        """Requirement 6: never leave the server unable to transcribe."""
        cli, auth, data_dir = client
        repo = _install_on_disk(data_dir, "small")
        assert (
            cli.put(
                "/v1/transcription/model", json={"name": "small"}, headers=auth
            ).status_code
            == 200
        )

        res = cli.delete("/v1/transcription/models/small", headers=auth)

        assert res.status_code == 409
        assert "active" in res.json()["detail"].lower()
        assert repo.exists(), "the active model's weights must survive"
        assert cli.get("/v1/transcription/models", headers=auth).json()["active"] == (
            "small"
        )

    def test_deleting_the_resolved_default_is_409_without_any_selection(self, client):
        """The active model is RESOLVED, not just the persisted row: with no
        selection made, large-v3 is live and must still be protected."""
        cli, auth, data_dir = client
        repo = _install_on_disk(data_dir, "large-v3")
        assert _setting(data_dir) is None

        res = cli.delete("/v1/transcription/models/large-v3", headers=auth)

        assert res.status_code == 409
        assert repo.exists()

    def test_unsupported_name_is_400(self, client):
        cli, auth, _ = client
        res = cli.delete("/v1/transcription/models/enormous-v9", headers=auth)
        assert res.status_code == 400
        assert "unsupported" in res.json()["detail"].lower()

    def test_delete_during_an_install_is_409(self, client, monkeypatch):
        import threading

        cli, auth, data_dir = client
        _install_on_disk(data_dir, "tiny")
        release = threading.Event()
        finish = _fake_downloader(data_dir)

        def blocking_downloader(name: str, cache_dir: str) -> None:
            release.wait(timeout=10)
            finish(name, cache_dir)

        monkeypatch.setattr(
            whisper_models, "default_downloader", blocking_downloader
        )
        try:
            assert (
                cli.post(
                    "/v1/transcription/models/small/install", headers=auth
                ).status_code
                == 202
            )
            res = cli.delete("/v1/transcription/models/tiny", headers=auth)
            assert res.status_code == 409
            assert "install" in res.json()["detail"].lower()
        finally:
            release.set()
        assert _wait_for(lambda: not whisper_models.install_running())

    def test_requires_auth(self, client):
        cli, _, _ = client
        assert cli.delete("/v1/transcription/models/tiny").status_code == 401
