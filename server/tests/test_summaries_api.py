# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for the /v1/summaries/* + /v1/dumps/{id}/summarize endpoints.

No real installs and no real model: summarizer_env's runner is injectable
and the worker's inference is stubbed. Auth is required on everything.
"""

from __future__ import annotations

import json
import sqlite3
import sys
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.db import init_db
from app.main import create_app
from app.services import summarizer_env, summarizer_worker


@pytest.fixture(autouse=True)
def _reset_state():
    summarizer_worker._reset_for_tests()
    summarizer_env._reset_state_for_tests()
    yield
    summarizer_worker._reset_for_tests()
    summarizer_env._reset_state_for_tests()


def fake_runner(step: summarizer_env.InstallStep) -> None:
    """Execute no real steps; emulate venv + weights so python_path() works."""
    if step.kind == "venv":
        dest = Path(step.dest)
        for cand in (dest / "Scripts" / "python.exe", dest / "bin" / "python"):
            cand.parent.mkdir(parents=True, exist_ok=True)
            cand.write_text("")
    if step.kind == "download":
        dest = Path(step.dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        with open(dest, "wb") as f:
            f.truncate(summarizer_env.MIN_MODEL_BYTES + 1)


@pytest.fixture
def client(temp_data_dir: Path, monkeypatch):
    monkeypatch.setattr(summarizer_env, "probe_gpu_visible", lambda: False)
    with TestClient(create_app()) as cli:
        token = cli.post("/v1/setup", json={"display_name": "T"}).json()["token"]
        yield cli, {"Authorization": f"Bearer {token}"}, temp_data_dir


def _wait_for(cond, timeout: float = 30.0) -> bool:
    """Poll ``cond`` until true or ``timeout``.

    30 s is deliberately generous: under full-suite load the install/worker
    threads these tests wait on can take well over the old 10 s to get
    scheduled (the two uninstall tests were flaky at 10 s while passing
    15/15 in isolation). A passing test never waits the full budget — the
    timeout only bounds a genuine failure.
    """
    deadline = time.time() + timeout
    while not cond() and time.time() < deadline:
        time.sleep(0.01)
    return cond()


def _open_db(data_dir: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    return conn


def _insert_dump(
    data_dir: Path,
    dump_id: str,
    transcript: str | None,
    mode: str = "meeting",
    summary: str | None = None,
) -> None:
    conn = _open_db(data_dir)
    try:
        conn.execute(
            "INSERT INTO dumps (id, client_id, created_at, updated_at, mode, "
            "duration_seconds, title, transcript, summary, summary_model, "
            "summarized_at, audio_kept) "
            "VALUES (?, 'single-user', 1, 1, ?, 60, 'T', ?, ?, ?, ?, 0)",
            (
                dump_id,
                mode,
                transcript,
                summary,
                "stem" if summary else None,
                111 if summary else None,
            ),
        )
        conn.commit()
    finally:
        conn.close()


def _install(monkeypatch) -> None:
    """Pretend the env is installed without any wizard round-trip."""
    monkeypatch.setattr(
        summarizer_env, "python_path", lambda: sys.executable
    )


# ---------------------------------------------------------------------------
# settings: capability + toggle
# ---------------------------------------------------------------------------


class TestSettings:
    def test_get_reports_capability_and_toggle_default_off(self, client):
        cli, auth, _ = client
        res = cli.get("/v1/summaries/settings", headers=auth)
        assert res.status_code == 200
        body = res.json()
        assert body["installed"] is False
        assert body["enabled"] is False
        assert body["install_running"] is False
        assert set(body) == {
            "installed", "runtime", "gpu_visible", "disk_free_bytes",
            "install_running", "enabled", "custom_prompt", "custom_configured",
        }
        assert body["custom_prompt"] is None
        assert body["custom_configured"] is False

    def test_post_persists_the_toggle_server_side(self, client):
        cli, auth, data_dir = client
        res = cli.post(
            "/v1/summaries/settings", json={"enabled": True}, headers=auth
        )
        assert res.status_code == 200
        assert res.json()["enabled"] is True
        # Persisted: a fresh GET (fresh db connection) still sees it.
        assert cli.get("/v1/summaries/settings", headers=auth).json()["enabled"] is True
        conn = _open_db(data_dir)
        try:
            row = conn.execute(
                "SELECT value FROM app_settings WHERE key = 'summaries_enabled'"
            ).fetchone()
        finally:
            conn.close()
        assert row["value"] == "1"

    def test_post_persists_and_clears_the_custom_prompt(self, client):
        cli, auth, data_dir = client
        authored = "Use these headings:\n## Wins\n## Risks"
        saved = cli.post(
            "/v1/summaries/settings",
            json={"custom_prompt": f"  {authored}  "},
            headers=auth,
        )
        assert saved.status_code == 200
        assert saved.json()["custom_prompt"] == authored
        assert saved.json()["custom_configured"] is True
        conn = _open_db(data_dir)
        try:
            row = conn.execute(
                "SELECT value FROM app_settings "
                "WHERE key = 'summary_custom_prompt'"
            ).fetchone()
        finally:
            conn.close()
        assert row["value"] == authored

        cleared = cli.post(
            "/v1/summaries/settings",
            json={"custom_prompt": "   "},
            headers=auth,
        )
        assert cleared.status_code == 200
        assert cleared.json()["custom_prompt"] is None
        assert cleared.json()["custom_configured"] is False

    def test_settings_require_auth(self, client):
        cli, _, _ = client
        assert cli.get("/v1/summaries/settings").status_code == 401
        assert (
            cli.post("/v1/summaries/settings", json={"enabled": True}).status_code
            == 401
        )


# ---------------------------------------------------------------------------
# install / progress / uninstall
# ---------------------------------------------------------------------------


class TestInstall:
    def test_install_202_then_progress_reaches_done(self, client, monkeypatch):
        cli, auth, _ = client
        monkeypatch.setattr(summarizer_env, "default_runner", fake_runner)

        res = cli.post("/v1/summaries/install", headers=auth)
        assert res.status_code == 202
        assert _wait_for(lambda: not summarizer_env.install_running())
        prog = cli.get("/v1/summaries/install/progress", headers=auth).json()
        assert prog["phase"] == "done"
        assert cli.get("/v1/summaries/settings", headers=auth).json()["installed"] is True

    def test_second_install_while_running_is_409(self, client, monkeypatch):
        import threading

        cli, auth, _ = client
        release = threading.Event()

        def blocking_runner(step: summarizer_env.InstallStep) -> None:
            release.wait(timeout=10)
            fake_runner(step)

        monkeypatch.setattr(summarizer_env, "default_runner", blocking_runner)
        try:
            assert cli.post("/v1/summaries/install", headers=auth).status_code == 202
            res = cli.post("/v1/summaries/install", headers=auth)
            assert res.status_code == 409, "409 = attach semantics for the wizard"
        finally:
            release.set()
        assert _wait_for(lambda: not summarizer_env.install_running())

    def test_live_install_completion_starts_the_worker(self, client, monkeypatch):
        """Wizard flow: toggle → install → summarizing, no restart."""
        cli, auth, _ = client
        monkeypatch.setattr(summarizer_env, "default_runner", fake_runner)
        assert not summarizer_worker.worker_running()

        assert cli.post("/v1/summaries/install", headers=auth).status_code == 202
        assert _wait_for(lambda: not summarizer_env.install_running())

        assert _wait_for(summarizer_worker.worker_running), (
            "a completed live install must start the worker without a restart"
        )

    def test_uninstall_deletes_env_but_keeps_summaries(self, client, monkeypatch):
        """The wizard's promise, both halves: env gone, summaries intact."""
        cli, auth, data_dir = client
        monkeypatch.setattr(summarizer_env, "default_runner", fake_runner)
        _insert_dump(
            data_dir, "d-keep", "Sam: hi", summary="## Summary\nPrecious."
        )

        assert cli.post("/v1/summaries/install", headers=auth).status_code == 202
        assert _wait_for(lambda: not summarizer_env.install_running())
        assert summarizer_env.env_dir().is_dir()

        res = cli.post("/v1/summaries/uninstall", headers=auth)
        assert res.status_code == 200
        assert res.json() == {"uninstalled": True}
        assert not summarizer_env.env_dir().exists(), "env dir must be deleted"

        conn = _open_db(data_dir)
        try:
            row = conn.execute(
                "SELECT summary, summary_model, summarized_at FROM dumps "
                "WHERE id = 'd-keep'"
            ).fetchone()
        finally:
            conn.close()
        assert row["summary"] == "## Summary\nPrecious.", (
            "uninstall must NOT touch stored summaries"
        )
        assert row["summary_model"] == "stem"
        assert row["summarized_at"] == 111

    def test_uninstall_quiesces_worker_and_queue_first(self, client, monkeypatch):
        cli, auth, _ = client
        monkeypatch.setattr(summarizer_env, "default_runner", fake_runner)
        assert cli.post("/v1/summaries/install", headers=auth).status_code == 202
        assert _wait_for(lambda: not summarizer_env.install_running())
        assert _wait_for(summarizer_worker.worker_running)
        summarizer_worker.enqueue("d-stale")

        assert cli.post("/v1/summaries/uninstall", headers=auth).status_code == 200

        assert _wait_for(lambda: not summarizer_worker.worker_running())
        assert summarizer_worker.pending() == [], (
            "queued dumps must not run against a deleted env"
        )

    def test_install_endpoints_require_auth(self, client):
        cli, _, _ = client
        assert cli.post("/v1/summaries/install").status_code == 401
        assert cli.get("/v1/summaries/install/progress").status_code == 401
        assert cli.post("/v1/summaries/uninstall").status_code == 401


# ---------------------------------------------------------------------------
# regenerate: POST /v1/dumps/{id}/summarize
# ---------------------------------------------------------------------------


class TestTemplates:
    def test_list_has_stable_exact_wire_shape(self, client):
        cli, auth, _ = client
        response = cli.get("/v1/summaries/templates", headers=auth)
        assert response.status_code == 200
        assert response.json() == {
            "templates": [
                {"id": "meeting", "display_name": "Meeting"},
                {"id": "brain_dump", "display_name": "Brain dump"},
                {"id": "lecture", "display_name": "Lecture"},
                {"id": "actions_only", "display_name": "Actions only"},
                {"id": "custom", "display_name": "Custom"},
            ],
            "custom_configured": False,
        }

    def test_list_reports_configured_custom_slot(self, client):
        cli, auth, _ = client
        cli.post(
            "/v1/summaries/settings",
            json={"custom_prompt": "## My format"},
            headers=auth,
        )
        body = cli.get("/v1/summaries/templates", headers=auth).json()
        assert body["custom_configured"] is True

    def test_list_requires_auth(self, client):
        cli, _, _ = client
        assert cli.get("/v1/summaries/templates").status_code == 401


class TestRegenerate:
    def test_unknown_dump_is_404(self, client, monkeypatch):
        cli, auth, _ = client
        _install(monkeypatch)
        res = cli.post("/v1/dumps/d-ghost/summarize", headers=auth)
        assert res.status_code == 404

    def test_dump_without_transcript_is_409(self, client, monkeypatch):
        cli, auth, data_dir = client
        _install(monkeypatch)
        _insert_dump(data_dir, "d-mute", None)
        res = cli.post("/v1/dumps/d-mute/summarize", headers=auth)
        assert res.status_code == 409
        assert "transcript" in res.json()["detail"].lower()

    def test_not_installed_is_409(self, client, temp_data_dir):
        cli, auth, data_dir = client
        _insert_dump(data_dir, "d-ok", "Sam: hi")
        res = cli.post("/v1/dumps/d-ok/summarize", headers=auth)
        assert res.status_code == 409
        assert "not installed" in res.json()["detail"].lower()

    def test_eligible_dump_is_202_and_enqueued(self, client, monkeypatch):
        cli, auth, data_dir = client
        _install(monkeypatch)
        # Keep the worker from consuming the entry before the assert.
        monkeypatch.setattr(
            "app.api.summaries.summarizer_worker.start_worker_if_installed",
            lambda: None,
        )
        _insert_dump(data_dir, "d-go", "Sam: hi")

        res = cli.post("/v1/dumps/d-go/summarize", headers=auth)

        assert res.status_code == 202
        assert res.json() == {"dump_id": "d-go", "status": "queued"}
        assert summarizer_worker.pending() == ["d-go"]

    def test_selected_template_is_committed_and_published_before_enqueue(
        self, client, monkeypatch
    ):
        cli, auth, data_dir = client
        _install(monkeypatch)
        _insert_dump(data_dir, "d-template", "Sam: hi")
        observed: dict[str, object] = {}

        def inspect_enqueue(dump_id: str) -> None:
            conn = _open_db(data_dir)
            try:
                row = conn.execute(
                    "SELECT summary_template FROM dumps WHERE id = ?", (dump_id,)
                ).fetchone()
                change = conn.execute(
                    "SELECT payload FROM change_log WHERE entity_id = ? "
                    "ORDER BY seq DESC",
                    (dump_id,),
                ).fetchone()
            finally:
                conn.close()
            observed["template"] = row["summary_template"]
            observed["payload"] = change["payload"]

        monkeypatch.setattr(summarizer_worker, "enqueue", inspect_enqueue)
        monkeypatch.setattr(summarizer_worker, "start_worker_if_installed", lambda: None)

        response = cli.post(
            "/v1/dumps/d-template/summarize",
            json={"template": "lecture"},
            headers=auth,
        )

        assert response.status_code == 202
        assert observed["template"] == "lecture"
        assert json.loads(observed["payload"])["summary_template"] == "lecture"

    @pytest.mark.parametrize("template", ["unknown", "", 42])
    def test_invalid_template_is_422_without_persist_or_enqueue(
        self, client, monkeypatch, template
    ):
        cli, auth, data_dir = client
        _install(monkeypatch)
        monkeypatch.setattr(summarizer_worker, "start_worker_if_installed", lambda: None)
        _insert_dump(data_dir, "d-invalid", "Sam: hi")

        response = cli.post(
            "/v1/dumps/d-invalid/summarize",
            json={"template": template},
            headers=auth,
        )

        assert response.status_code == 422
        conn = _open_db(data_dir)
        try:
            stored = conn.execute(
                "SELECT summary_template FROM dumps WHERE id = 'd-invalid'"
            ).fetchone()["summary_template"]
        finally:
            conn.close()
        assert stored is None
        assert summarizer_worker.pending() == []

    def test_unconfigured_custom_template_is_422(self, client, monkeypatch):
        cli, auth, data_dir = client
        _install(monkeypatch)
        _insert_dump(data_dir, "d-custom", "Sam: hi")
        response = cli.post(
            "/v1/dumps/d-custom/summarize",
            json={"template": "custom"},
            headers=auth,
        )
        assert response.status_code == 422
        assert "not configured" in response.json()["detail"].lower()

    def test_regenerate_accepts_non_meeting_dumps(self, client, monkeypatch):
        """Auto-trigger is meeting-only; regenerate accepts ANY transcript."""
        cli, auth, data_dir = client
        _install(monkeypatch)
        monkeypatch.setattr(
            "app.api.summaries.summarizer_worker.start_worker_if_installed",
            lambda: None,
        )
        _insert_dump(data_dir, "d-brain", "note to self", mode="brain_dump")

        res = cli.post("/v1/dumps/d-brain/summarize", headers=auth)
        assert res.status_code == 202
        assert summarizer_worker.pending() == ["d-brain"]

    def test_regenerate_requires_auth(self, client):
        cli, _, _ = client
        assert cli.post("/v1/dumps/d-x/summarize").status_code == 401
