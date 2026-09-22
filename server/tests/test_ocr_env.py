# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for the on-demand OCR environment install manager (Task 2).

The runner that executes venv/pip/download/verify steps is injected — no test
installs a real package or downloads a real model. The real default runner is
exercised only through the shape of the steps it would receive.
"""

from __future__ import annotations

import json
import sqlite3
import threading
import time
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.auth import generate_token, hash_token
from app.db import init_db
from app.services import ocr_env

CU128_INDEX = "https://download.pytorch.org/whl/cu128"
CPU_INDEX = "https://download.pytorch.org/whl/cpu"


@pytest.fixture(autouse=True)
def _reset_ocr_state():
    """ocr_env keeps module-level install state; isolate every test."""
    ocr_env._reset_state_for_tests()
    yield
    ocr_env._reset_state_for_tests()


class RecordingRunner:
    """Fake step runner.

    Records every step and the progress visible while it ran, emulates venv
    creation (touches the interpreter files), optionally blocks on an Event
    or raises when a given phase is reached.
    """

    def __init__(
        self,
        fail_on_phase: str | None = None,
        block: threading.Event | None = None,
    ) -> None:
        self.steps: list[ocr_env.InstallStep] = []
        self.progress_seen: list[dict] = []
        self.final_dir_seen: list[bool] = []
        self.fail_on_phase = fail_on_phase
        self.block = block

    def __call__(self, step: ocr_env.InstallStep) -> None:
        self.steps.append(step)
        self.progress_seen.append(dict(ocr_env.progress()))
        self.final_dir_seen.append(ocr_env.env_dir().exists())
        if self.block is not None:
            assert self.block.wait(timeout=10), "test never released the blocked runner"
        if step.phase == self.fail_on_phase:
            raise RuntimeError(f"boom during {step.phase}")
        if step.kind == "venv":
            dest = Path(step.dest)
            for cand in (dest / "Scripts" / "python.exe", dest / "bin" / "python"):
                cand.parent.mkdir(parents=True, exist_ok=True)
                cand.write_text("")


def _wait_not_running(timeout: float = 10.0) -> None:
    deadline = time.time() + timeout
    while ocr_env.install_running() and time.time() < deadline:
        time.sleep(0.01)
    assert not ocr_env.install_running(), "install never finished"


# ---------------------------------------------------------------------------
# Service: install engine
# ---------------------------------------------------------------------------


def test_install_phase_sequence_and_monotonic_percent(temp_data_dir):
    runner = RecordingRunner()
    ocr_env.install("cpu", runner=runner)

    assert [s.phase for s in runner.steps] == [
        "venv",
        "torch",
        "transformers",
        "weights",
        "verify",
    ]
    percents = [p["percent"] for p in runner.progress_seen]
    percents.append(ocr_env.progress()["percent"])
    assert all(b > a for a, b in zip(percents, percents[1:], strict=False)), (
        f"percent must strictly increase across phases, got {percents}"
    )
    done = ocr_env.progress()
    assert done["phase"] == "done"
    assert done["percent"] == 100


def test_install_is_atomic_and_writes_verified_marker(temp_data_dir):
    runner = RecordingRunner()
    ocr_env.install("cpu", runner=runner)

    # Nothing may exist at the final path until every step (self-test
    # included) has succeeded.
    assert not any(runner.final_dir_seen), "final env dir appeared mid-install"

    env = ocr_env.env_dir()
    assert env.is_dir()
    assert not ocr_env.tmp_env_dir().exists(), "tmp dir must be renamed away"
    marker = json.loads((env / "verified.json").read_text(encoding="utf-8"))
    assert marker["flavour"] == "cpu"
    assert marker["model"] == ocr_env.MODEL_ID


def test_install_failure_during_torch_leaves_no_env_dir(temp_data_dir):
    runner = RecordingRunner(fail_on_phase="torch")
    with pytest.raises(ocr_env.InstallError):
        ocr_env.install("cpu", runner=runner)

    assert not ocr_env.env_dir().exists(), "failed install must leave NO ocr-env"
    assert not ocr_env.tmp_env_dir().exists(), "failed install must clean up tmp"
    prog = ocr_env.progress()
    assert prog["phase"] == "failed"
    assert "torch" in prog["detail"]
    assert "boom" in prog["detail"]
    assert not ocr_env.install_running()


def test_install_rejects_unknown_flavour(temp_data_dir):
    with pytest.raises(ValueError):
        ocr_env.install("tpu", runner=RecordingRunner())


def test_gpu_flavour_steps_pin_torch_index_model_and_verify(temp_data_dir):
    runner = RecordingRunner()
    ocr_env.install("gpu", runner=runner)
    by_phase = {s.phase: s for s in runner.steps}

    assert CU128_INDEX in by_phase["torch"].argv
    # The full plan-mandated dep set — not just the transformers pin.
    transformers_argv = by_phase["transformers"].argv
    for dep in (
        "transformers>=4.46,<5",
        "pillow",
        "sentencepiece",
        "protobuf",
        "huggingface_hub",
    ):
        assert dep in transformers_argv, f"{dep!r} missing from transformers step argv"

    weights = by_phase["weights"]
    assert weights.kind == "download"
    assert weights.repo_id == "microsoft/trocr-base-handwritten"
    assert "models" in Path(weights.dest).parts

    verify = by_phase["verify"]
    assert verify.argv[-1] == "--selftest"
    assert verify.argv[-2].endswith("ocr_infer.py")
    # Verify runs against the tmp venv (pre-rename), with its python.
    assert "ocr-env.tmp" in verify.argv[0]

    # Both flavours use the same model — only the torch index differs.
    marker = json.loads((ocr_env.env_dir() / "verified.json").read_text(encoding="utf-8"))
    assert marker["flavour"] == "gpu"
    assert marker["model"] == "microsoft/trocr-base-handwritten"


def test_cpu_flavour_uses_cpu_wheel_index(temp_data_dir):
    runner = RecordingRunner()
    ocr_env.install("cpu", runner=runner)
    torch_step = next(s for s in runner.steps if s.phase == "torch")
    assert CPU_INDEX in torch_step.argv
    assert CU128_INDEX not in torch_step.argv


def test_reinstall_over_existing_env_switches_flavour(temp_data_dir, monkeypatch):
    """Installing over an already-verified env must replace it (flavour switch).

    Pins the rmtree(final)-before-rename publish step: without it, rename onto
    the existing dir raises, the rollback deletes the fresh tmp env, and
    flavour switching silently becomes impossible without a manual uninstall.
    """
    monkeypatch.setattr(ocr_env, "probe_gpu_visible", lambda: False)
    ocr_env.install("cpu", runner=RecordingRunner())
    assert ocr_env.capability()["flavour"] == "cpu"

    ocr_env.install("gpu", runner=RecordingRunner())  # must NOT raise

    cap = ocr_env.capability()
    assert cap["installed"] is True
    assert cap["flavour"] == "gpu", "re-install must switch the verified flavour"
    assert not ocr_env.tmp_env_dir().exists(), "tmp dir must be renamed away"
    marker = json.loads((ocr_env.env_dir() / "verified.json").read_text(encoding="utf-8"))
    assert marker["flavour"] == "gpu"
    assert ocr_env.progress()["phase"] == "done"


def test_second_install_while_running_raises_conflict(temp_data_dir):
    release = threading.Event()
    runner = RecordingRunner(block=release)
    thread = ocr_env.start_install("cpu", runner=runner)
    try:
        with pytest.raises(ocr_env.InstallInProgress):
            ocr_env.install("cpu", runner=RecordingRunner())
        assert ocr_env.install_running()
    finally:
        release.set()
        thread.join(timeout=10)
    _wait_not_running()
    assert ocr_env.progress()["phase"] == "done"


# ---------------------------------------------------------------------------
# Service: python_path / capability / probe / uninstall
# ---------------------------------------------------------------------------


def test_python_path_none_until_verified_install(temp_data_dir):
    assert ocr_env.python_path() is None
    ocr_env.install("cpu", runner=RecordingRunner())
    p = ocr_env.python_path()
    assert p is not None
    path = Path(p)
    assert path.exists()
    assert "ocr-env" in path.parts
    assert "venv" in path.parts


def test_capability_truth_table(temp_data_dir, monkeypatch):
    monkeypatch.setattr(ocr_env, "probe_gpu_visible", lambda: False)

    cap = ocr_env.capability()
    assert cap["installed"] is False
    assert cap["flavour"] is None
    assert cap["gpu_visible"] is False
    assert cap["install_running"] is False
    assert isinstance(cap["disk_free_bytes"], int)
    assert cap["disk_free_bytes"] > 0

    ocr_env.install("gpu", runner=RecordingRunner())
    monkeypatch.setattr(ocr_env, "probe_gpu_visible", lambda: True)
    cap = ocr_env.capability()
    assert cap["installed"] is True
    assert cap["flavour"] == "gpu"
    assert cap["gpu_visible"] is True
    assert cap["install_running"] is False


def test_capability_dir_without_verify_marker_is_not_installed(temp_data_dir):
    ocr_env.env_dir().mkdir(parents=True)
    cap = ocr_env.capability()
    assert cap["installed"] is False
    assert cap["flavour"] is None


def test_probe_gpu_visible_no_nvidia_smi_is_false(monkeypatch):
    def _raise(*args, **kwargs):
        raise FileNotFoundError("nvidia-smi")

    monkeypatch.setattr(ocr_env.subprocess, "run", _raise)
    assert ocr_env.probe_gpu_visible() is False


def test_probe_gpu_visible_exit_code_and_output(monkeypatch):
    class Proc:
        def __init__(self, returncode, stdout):
            self.returncode = returncode
            self.stdout = stdout

    outcomes = {"proc": Proc(0, "GPU 0: NVIDIA GeForce RTX 3080\n")}
    monkeypatch.setattr(
        ocr_env.subprocess, "run", lambda *a, **k: outcomes["proc"]
    )
    assert ocr_env.probe_gpu_visible() is True

    outcomes["proc"] = Proc(1, "")
    assert ocr_env.probe_gpu_visible() is False

    outcomes["proc"] = Proc(0, "   ")  # zero exit but no GPUs listed
    assert ocr_env.probe_gpu_visible() is False


def _open_db(data_dir: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    return conn


def test_uninstall_removes_env_and_tolerates_missing_ink_index(temp_data_dir):
    init_db(str(temp_data_dir))
    ocr_env.install("cpu", runner=RecordingRunner())
    # A stale tmp build (e.g. from a crashed install) must also be removed.
    stale_tmp = ocr_env.tmp_env_dir()
    stale_tmp.mkdir(parents=True)
    (stale_tmp / "leftover.txt").write_text("crashed install debris", encoding="utf-8")
    conn = _open_db(temp_data_dir)
    try:
        # ink_index does not exist yet (Task 3 owns that schema) — must not raise.
        assert ocr_env.uninstall(conn) is True
    finally:
        conn.close()
    assert not ocr_env.env_dir().exists()
    assert not ocr_env.tmp_env_dir().exists(), "uninstall must delete stale ocr-env.tmp"
    assert ocr_env.python_path() is None
    cap_installed = ocr_env.capability()["installed"]
    assert cap_installed is False


def test_uninstall_drops_ink_index_rows_when_table_exists(temp_data_dir):
    init_db(str(temp_data_dir))
    ocr_env.install("cpu", runner=RecordingRunner())
    conn = _open_db(temp_data_dir)
    try:
        # Task 3's real schema — init_db created the table.
        conn.execute(
            "INSERT INTO ink_index (id, notebook_id, line_id, word_text, "
            "word_text_lower, bbox_json, stroke_ids_json, model, indexed_at) "
            "VALUES ('l1:000', 'nb-1', 'l1', 'hello', 'hello', '[0,0,1,1]', "
            "'[\"s-1\"]', 'm', 1)"
        )
        conn.commit()
        ocr_env.uninstall(conn)
        count = conn.execute("SELECT COUNT(*) FROM ink_index").fetchone()[0]
    finally:
        conn.close()
    assert count == 0


# ---------------------------------------------------------------------------
# API endpoints
# ---------------------------------------------------------------------------


@pytest.fixture
def api_client(temp_data_dir: Path):
    init_db(str(temp_data_dir))
    token = generate_token()
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        conn.execute(
            "INSERT INTO auth (id, token_hash, display_name, created_at) VALUES (1, ?, ?, ?)",
            (hash_token(token), "TestUser", int(time.time())),
        )
        conn.commit()
    finally:
        conn.close()

    from app.api.ocr import router as ocr_router

    app = FastAPI()
    app.include_router(ocr_router)
    return TestClient(app), token


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def test_all_ocr_endpoints_require_auth(api_client):
    cli, _ = api_client
    assert cli.get("/v1/ocr/capability").status_code == 401
    assert cli.post("/v1/ocr/install", json={"flavour": "cpu"}).status_code == 401
    assert cli.get("/v1/ocr/install/progress").status_code == 401
    assert cli.post("/v1/ocr/uninstall").status_code == 401


def test_capability_endpoint_shape(api_client, monkeypatch):
    cli, token = api_client
    monkeypatch.setattr(ocr_env, "probe_gpu_visible", lambda: False)
    resp = cli.get("/v1/ocr/capability", headers=_auth(token))
    assert resp.status_code == 200
    body = resp.json()
    assert body["installed"] is False
    assert body["flavour"] is None
    assert body["gpu_visible"] is False
    assert isinstance(body["disk_free_bytes"], int)
    assert body["install_running"] is False


def test_progress_endpoint_idle_before_any_install(api_client):
    cli, token = api_client
    resp = cli.get("/v1/ocr/install/progress", headers=_auth(token))
    assert resp.status_code == 200
    assert resp.json() == {"phase": "idle", "percent": 0, "detail": ""}


def test_install_endpoint_202_progress_409_then_completes(api_client, monkeypatch):
    cli, token = api_client
    release = threading.Event()
    runner = RecordingRunner(block=release)
    monkeypatch.setattr(ocr_env, "default_runner", runner)
    monkeypatch.setattr(ocr_env, "probe_gpu_visible", lambda: False)

    try:
        resp = cli.post("/v1/ocr/install", json={"flavour": "cpu"}, headers=_auth(token))
        assert resp.status_code == 202
        assert resp.json()["flavour"] == "cpu"

        # Progress is readable while the install thread is blocked.
        prog = cli.get("/v1/ocr/install/progress", headers=_auth(token)).json()
        assert prog["phase"] == "venv"
        assert isinstance(prog["percent"], int)

        # Concurrent install attempt → 409.
        dup = cli.post("/v1/ocr/install", json={"flavour": "cpu"}, headers=_auth(token))
        assert dup.status_code == 409

        # capability() must report the running install (the wizard's
        # "install in progress" signal) — not just default to False.
        cap = cli.get("/v1/ocr/capability", headers=_auth(token)).json()
        assert cap["install_running"] is True
    finally:
        release.set()

    _wait_not_running()
    prog = cli.get("/v1/ocr/install/progress", headers=_auth(token)).json()
    assert prog["phase"] == "done"
    assert prog["percent"] == 100
    cap = cli.get("/v1/ocr/capability", headers=_auth(token)).json()
    assert cap["installed"] is True
    assert cap["flavour"] == "cpu"
    assert cap["install_running"] is False


def test_install_endpoint_rejects_unknown_flavour(api_client):
    cli, token = api_client
    resp = cli.post("/v1/ocr/install", json={"flavour": "tpu"}, headers=_auth(token))
    assert resp.status_code == 422


def test_uninstall_endpoint_removes_env(api_client, monkeypatch):
    cli, token = api_client
    monkeypatch.setattr(ocr_env, "probe_gpu_visible", lambda: False)
    ocr_env.install("cpu", runner=RecordingRunner())

    resp = cli.post("/v1/ocr/uninstall", headers=_auth(token))
    assert resp.status_code == 200
    assert resp.json() == {"uninstalled": True}
    assert not ocr_env.env_dir().exists()
    cap = cli.get("/v1/ocr/capability", headers=_auth(token)).json()
    assert cap["installed"] is False


def test_uninstall_endpoint_409_while_install_running(api_client, monkeypatch):
    cli, token = api_client
    release = threading.Event()
    runner = RecordingRunner(block=release)
    monkeypatch.setattr(ocr_env, "default_runner", runner)

    try:
        assert (
            cli.post("/v1/ocr/install", json={"flavour": "cpu"}, headers=_auth(token)).status_code
            == 202
        )
        resp = cli.post("/v1/ocr/uninstall", headers=_auth(token))
        assert resp.status_code == 409
    finally:
        release.set()
    _wait_not_running()
