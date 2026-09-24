# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for the AI-summaries server plumbing (Task 1).

Covers ``app/summarize_infer.py`` — the standalone llama.cpp inference
script. Nothing here loads a real model: llama-cpp is imported only inside
``_load_llm``, which these tests replace with fakes, exactly like the
ocr_infer tests avoid importing torch.
"""

from __future__ import annotations

import io
import json
import os
import threading
import time
from pathlib import Path

import pytest

from app import summarize_infer
from app.services import summarizer_env

# ---------------------------------------------------------------------------
# summarize_infer: constants + system prompt (binding per the plan)
# ---------------------------------------------------------------------------


def test_sampling_constants_are_the_validated_ones():
    assert summarize_infer.TEMPERATURE == 0.2
    assert summarize_infer.MAX_TOKENS == 1024
    assert summarize_infer.CTX_TOKENS == 8192


def test_system_prompt_names_all_four_sections_in_order():
    prompt = summarize_infer.SYSTEM_PROMPT
    positions = [
        prompt.index(h)
        for h in ("## Summary", "## Key decisions", "## Action items", "## Open questions")
    ]
    assert positions == sorted(positions), "sections must appear in template order"


def test_system_prompt_has_no_invention_rules_and_one_worked_example():
    prompt = summarize_infer.SYSTEM_PROMPT
    assert "extract exhaustively" in prompt.lower()
    assert "only include items explicitly discussed" in prompt.lower()
    assert "never invent names, numbers, or dates" in prompt.lower()
    # Language follows the transcript (Qwen language-lock needs the rule).
    assert "same language as the transcript" in prompt.lower()
    # Exactly ONE worked example (rules + one example was the validated shape):
    # the example contributes the second occurrence of each section heading.
    assert prompt.count("## Summary") == 2, "expected template + exactly one worked example"


def test_infer_script_never_imports_llama_at_module_level():
    """The server imports this module for constants; llama_cpp must load
    only inside functions that run in the summarizer env."""
    import ast

    tree = ast.parse(Path(summarize_infer.__file__).read_text(encoding="utf-8"))
    top_level = {
        name.name.split(".")[0]
        for node in tree.body
        if isinstance(node, ast.Import)
        for name in node.names
    } | {
        node.module.split(".")[0]
        for node in tree.body
        if isinstance(node, ast.ImportFrom) and node.module
    }
    assert "llama_cpp" not in top_level
    assert "app" not in top_level, "standalone script must not import server code"


def test_default_model_path_derives_from_the_venv_interpreter():
    win = summarize_infer.default_model_path("C:/data/summarizer-env/venv/Scripts/python.exe")
    posix = summarize_infer.default_model_path("/data/summarizer-env/venv/bin/python")
    for path in (win, posix):
        assert path.name == summarize_infer.MODEL_FILENAME
        assert path.parent.name == "models"
        assert path.parent.parent.name == "summarizer-env"


# ---------------------------------------------------------------------------
# summarize_infer: postprocess (None-placeholder stripping, binding template)
# ---------------------------------------------------------------------------


FULL = (
    "## Summary\n"
    "The team agreed to ship v2 on Monday.\n"
    "\n"
    "## Key decisions\n"
    "- Ship v2 on Monday.\n"
    "\n"
    "## Action items\n"
    "- Bob: write the release notes.\n"
    "\n"
    "## Open questions\n"
    "- Who runs the launch call?"
)


def test_postprocess_keeps_a_fully_populated_summary_byte_stable():
    assert summarize_infer.postprocess(FULL) == FULL


@pytest.mark.parametrize(
    "placeholder",
    ["None", "- None", "-None", "none", "- NONE", "None.", "- None identified."],
)
def test_postprocess_strips_sections_whose_only_content_is_none(placeholder):
    text = (
        "## Summary\n"
        "Short chat about logistics.\n"
        "\n"
        "## Key decisions\n"
        f"{placeholder}\n"
        "\n"
        "## Action items\n"
        "- Ana: book the room.\n"
        "\n"
        "## Open questions\n"
        f"{placeholder}"
    )
    out = summarize_infer.postprocess(text)
    assert out == (
        "## Summary\n"
        "Short chat about logistics.\n"
        "\n"
        "## Action items\n"
        "- Ana: book the room."
    )


def test_postprocess_keeps_sections_with_real_content_beside_a_none_line():
    text = "## Key decisions\n- None\n- Use Postgres."
    assert summarize_infer.postprocess(text) == text


def test_postprocess_strips_trailing_standalone_heading_with_no_body():
    text = "## Summary\nAll done.\n\n## Open questions"
    assert summarize_infer.postprocess(text) == "## Summary\nAll done."


def test_postprocess_does_not_treat_phrases_containing_none_as_placeholders():
    text = "## Key decisions\n- Nonetheless we proceed.\n- None of the vendors made the cut."
    out = summarize_infer.postprocess(text)
    # "Nonetheless" has no word-boundary match; "None of the vendors" does —
    # but the section still has a non-placeholder line, so it survives whole.
    assert out == text


def test_postprocess_all_sections_empty_yields_empty_string():
    text = "## Summary\n- None\n\n## Key decisions\n- None"
    assert summarize_infer.postprocess(text) == ""


# ---------------------------------------------------------------------------
# summarize_infer: --serve protocol (fake llm; no model load)
# ---------------------------------------------------------------------------


class FakeLlm:
    """Stands in for llama_cpp.Llama: create_chat_completion only."""

    def __init__(self, content="## Summary\nFine.\n\n## Key decisions\n- None"):
        self.content = content
        self.calls: list[dict] = []

    def create_chat_completion(self, **kwargs):
        self.calls.append(kwargs)
        if isinstance(self.content, Exception):
            raise self.content
        return {"choices": [{"message": {"content": self.content}}]}


def _run_serve(monkeypatch, capsys, stdin_text: str, llm: FakeLlm):
    monkeypatch.setattr(summarize_infer, "_load_llm", lambda path: llm)
    monkeypatch.setattr(summarize_infer.sys, "stdin", io.StringIO(stdin_text))
    rc = summarize_infer.serve(Path("unused.gguf"))
    assert rc == 0
    return [json.loads(line) for line in capsys.readouterr().out.splitlines() if line.strip()]


def test_serve_answers_one_json_line_per_request(monkeypatch, capsys):
    llm = FakeLlm()
    requests = (
        json.dumps({"id": "d-1", "transcript": "Ana: hello"})
        + "\n"
        + json.dumps({"id": "d-2", "transcript": "Ben: bye"})
        + "\n"
    )
    out = _run_serve(monkeypatch, capsys, requests, llm)
    assert out == [
        {"id": "d-1", "summary": "## Summary\nFine."},
        {"id": "d-2", "summary": "## Summary\nFine."},
    ]
    # The system prompt + sampling params reach the model on every call.
    for call in llm.calls:
        assert call["messages"][0] == {"role": "system", "content": summarize_infer.SYSTEM_PROMPT}
        assert call["temperature"] == summarize_infer.TEMPERATURE
        assert call["max_tokens"] == summarize_infer.MAX_TOKENS
    assert [c["messages"][1]["content"] for c in llm.calls] == ["Ana: hello", "Ben: bye"]


def test_serve_reports_per_request_errors_and_keeps_serving(monkeypatch, capsys):
    llm = FakeLlm()
    lines = (
        "this is not json\n"
        + json.dumps({"id": "d-3"})  # missing transcript
        + "\n"
        + json.dumps({"id": "d-4", "transcript": "Cara: hi"})
        + "\n"
    )
    out = _run_serve(monkeypatch, capsys, lines, llm)
    assert len(out) == 3, "one bad line must not kill the server"
    assert "error" in out[0] and out[0]["id"] == ""
    assert out[1] == {"id": "d-3", "error": out[1]["error"]} and "transcript" in out[1]["error"]
    assert out[2] == {"id": "d-4", "summary": "## Summary\nFine."}


def test_serve_model_failure_is_an_error_line_not_a_crash(monkeypatch, capsys):
    llm = FakeLlm(content=RuntimeError("kv cache exploded"))
    out = _run_serve(
        monkeypatch, capsys, json.dumps({"id": "d-5", "transcript": "Dee: hm"}) + "\n", llm
    )
    assert out == [{"id": "d-5", "error": "RuntimeError: kv cache exploded"}]


# ---------------------------------------------------------------------------
# summarize_infer: --selftest (the installer's verify hook)
# ---------------------------------------------------------------------------


def test_selftest_exits_zero_and_prints_nonempty_summary(monkeypatch, capsys):
    monkeypatch.setattr(summarize_infer, "_load_llm", lambda path: FakeLlm())
    rc = summarize_infer.main(["--selftest", "--model-path", "unused.gguf"])
    assert rc == 0
    assert capsys.readouterr().out.strip() != ""


def test_selftest_fails_nonzero_when_summary_is_empty(monkeypatch, capsys):
    # A model that only emits placeholders postprocesses to "" — that is a
    # broken install, and the installer must NOT publish the env.
    monkeypatch.setattr(
        summarize_infer, "_load_llm", lambda path: FakeLlm(content="## Summary\n- None")
    )
    rc = summarize_infer.main(["--selftest", "--model-path", "unused.gguf"])
    assert rc == 1
    assert "selftest failed" in capsys.readouterr().err


def test_main_requires_exactly_one_mode():
    with pytest.raises(SystemExit):
        summarize_infer.main([])


# ---------------------------------------------------------------------------
# summarizer_env: install engine (fake runner — no pip, no 2.5 GB download)
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _reset_summarizer_state():
    """summarizer_env keeps module-level install state; isolate every test."""
    summarizer_env._reset_state_for_tests()
    yield
    summarizer_env._reset_state_for_tests()


@pytest.fixture
def small_weights(monkeypatch):
    """Shrink the GGUF size floor so fakes need not create 2.5 GB files.

    Two dedicated tests exercise the REAL floor (sparse file / tiny file);
    everything else only needs 'big enough'.
    """
    monkeypatch.setattr(summarizer_env, "MIN_MODEL_BYTES", 1000)


class RecordingRunner:
    """Fake step runner: records steps + visible progress, emulates venv
    creation and the weights download (sparse file), optionally blocks on an
    Event, raises at a phase, or fails only argv containing a marker (the
    CUDA-attempt seam)."""

    def __init__(
        self,
        fail_on_phase: str | None = None,
        fail_argv_containing: str | None = None,
        block: threading.Event | None = None,
        weights_size: int | None = None,
        fail_verify_times: int = 0,
    ) -> None:
        self.steps: list[summarizer_env.InstallStep] = []
        self.progress_seen: list[dict] = []
        self.final_dir_seen: list[bool] = []
        self.fail_on_phase = fail_on_phase
        self.fail_argv_containing = fail_argv_containing
        self.block = block
        self.weights_size = weights_size
        self.fail_verify_times = fail_verify_times
        self._verify_failures = 0

    def __call__(self, step: summarizer_env.InstallStep) -> None:
        self.steps.append(step)
        self.progress_seen.append(dict(summarizer_env.progress()))
        self.final_dir_seen.append(summarizer_env.env_dir().exists())
        if self.block is not None:
            assert self.block.wait(timeout=10), "test never released the blocked runner"
        if step.phase == "verify" and self.fail_verify_times > 0:
            self.fail_verify_times -= 1
            self._verify_failures += 1
            raise RuntimeError(
                f"selftest exited 1 (attempt {self._verify_failures}): "
                "libcudart.so.12 missing"
            )
        if step.phase == self.fail_on_phase:
            raise RuntimeError(f"boom during {step.phase}")
        if self.fail_argv_containing and any(
            self.fail_argv_containing in a for a in step.argv
        ):
            raise RuntimeError(f"boom on argv containing {self.fail_argv_containing}")
        if step.kind == "venv":
            dest = Path(step.dest)
            for cand in (dest / "Scripts" / "python.exe", dest / "bin" / "python"):
                cand.parent.mkdir(parents=True, exist_ok=True)
                cand.write_text("")
        if step.kind == "download":
            dest = Path(step.dest)
            dest.parent.mkdir(parents=True, exist_ok=True)
            size = (
                self.weights_size
                if self.weights_size is not None
                else summarizer_env.MIN_MODEL_BYTES + 1
            )
            with open(dest, "wb") as f:
                f.truncate(size)


def _wait_not_running(timeout: float = 10.0) -> None:
    deadline = time.time() + timeout
    while summarizer_env.install_running() and time.time() < deadline:
        time.sleep(0.01)
    assert not summarizer_env.install_running(), "install never finished"


def test_install_phase_sequence_and_monotonic_percent(temp_data_dir, monkeypatch, small_weights):
    monkeypatch.setattr(summarizer_env, "probe_gpu_visible", lambda: False)
    runner = RecordingRunner()
    summarizer_env.install(runner=runner)

    assert [s.phase for s in runner.steps] == ["venv", "runtime", "weights", "verify"]
    percents = [p["percent"] for p in runner.progress_seen]
    percents.append(summarizer_env.progress()["percent"])
    assert all(b > a for a, b in zip(percents, percents[1:], strict=False)), (
        f"percent must strictly increase across phases, got {percents}"
    )
    done = summarizer_env.progress()
    assert done["phase"] == "done"
    assert done["percent"] == 100


def test_install_is_atomic_and_writes_verified_marker(temp_data_dir, monkeypatch, small_weights):
    monkeypatch.setattr(summarizer_env, "probe_gpu_visible", lambda: False)
    runner = RecordingRunner()
    summarizer_env.install(runner=runner)

    assert not any(runner.final_dir_seen), "final env dir appeared mid-install"
    env = summarizer_env.env_dir()
    assert env.is_dir()
    assert not summarizer_env.tmp_env_dir().exists(), "tmp dir must be renamed away"
    marker = json.loads((env / "verified.json").read_text(encoding="utf-8"))
    assert marker["model"] == summarize_infer.MODEL_FILENAME
    assert marker["runtime"] == "cpu"


def test_selftest_failure_leaves_no_env_and_phase_failed(temp_data_dir, monkeypatch, small_weights):
    """The plan-named failure case: verify (--selftest) fails so the progress
    phase goes 'failed' AND the tmp dir is removed. Nothing is published."""
    monkeypatch.setattr(summarizer_env, "probe_gpu_visible", lambda: False)
    runner = RecordingRunner(fail_on_phase="verify")
    with pytest.raises(summarizer_env.InstallError):
        summarizer_env.install(runner=runner)

    assert not summarizer_env.env_dir().exists(), "failed install must leave NO env"
    assert not summarizer_env.tmp_env_dir().exists(), "failed install must clean up tmp"
    prog = summarizer_env.progress()
    assert prog["phase"] == "failed"
    assert "verify" in prog["detail"]
    assert "boom" in prog["detail"]
    assert not summarizer_env.install_running()


# ---------------------------------------------------------------------------
# verify-time CPU downgrade (the live-E2E lesson: a CUDA wheel that INSTALLS
# fine can still fail its selftest — e.g. missing driver/runtime pieces.
# CPU is the guaranteed baseline, so the installer retries once on CPU.)
# ---------------------------------------------------------------------------


class _EnvWarningLog:
    """Records log.warning events on summarizer_env; other levels no-op."""

    def __init__(self) -> None:
        self.warnings: list[tuple[str, dict]] = []

    def __getattr__(self, name):
        def _record(event, **kw):
            if name == "warning":
                self.warnings.append((event, kw))

        return _record


def test_cuda_selftest_failure_downgrades_to_cpu_wheel_once_and_succeeds(
    temp_data_dir, monkeypatch, small_weights
):
    monkeypatch.setattr(summarizer_env, "probe_gpu_visible", lambda: True)
    fake_log = _EnvWarningLog()
    monkeypatch.setattr(summarizer_env, "log", fake_log)
    runner = RecordingRunner(fail_verify_times=1)

    summarizer_env.install(runner=runner)  # must NOT raise — CPU retry saves it

    phases = [s.phase for s in runner.steps]
    assert phases == ["venv", "runtime", "weights", "verify", "runtime", "verify"], (
        "one CPU reinstall + one re-selftest, nothing else"
    )
    downloads = [s for s in runner.steps if s.kind == "download"]
    assert len(downloads) == 1, "the retry must NOT re-download the weights"

    retry_pip = runner.steps[4]
    assert retry_pip.kind == "pip"
    assert any(summarizer_env.CPU_WHEEL_INDEX in a for a in retry_pip.argv)
    assert "--force-reinstall" in retry_pip.argv, (
        "the CUDA wheel is already installed — the CPU wheel must replace it"
    )
    assert not any("nvidia-" in a for a in retry_pip.argv), (
        "the CPU retry must not reinstall CUDA runtime wheels"
    )

    assert summarizer_env.progress()["phase"] == "done"
    marker = json.loads(
        (summarizer_env.env_dir() / "verified.json").read_text(encoding="utf-8")
    )
    assert marker["runtime"] == "cpu", "the downgrade must be recorded"
    assert any(
        e == "summarizer_env.cuda_selftest_failed_downgrading"
        for e, _ in fake_log.warnings
    ), "the downgrade must be logged"


def test_both_selftests_failing_fails_install_with_the_cpu_error(
    temp_data_dir, monkeypatch, small_weights
):
    monkeypatch.setattr(summarizer_env, "probe_gpu_visible", lambda: True)
    runner = RecordingRunner(fail_verify_times=2)

    with pytest.raises(summarizer_env.InstallError):
        summarizer_env.install(runner=runner)

    phases = [s.phase for s in runner.steps]
    assert phases == ["venv", "runtime", "weights", "verify", "runtime", "verify"], (
        "exactly ONE downgrade retry — never a loop"
    )
    prog = summarizer_env.progress()
    assert prog["phase"] == "failed"
    assert "attempt 2" in prog["detail"], (
        "the CPU selftest's error (the final word) must be the one surfaced"
    )
    assert not summarizer_env.env_dir().exists()
    assert not summarizer_env.tmp_env_dir().exists()


def test_cpu_selftest_failure_never_triggers_a_downgrade_retry(
    temp_data_dir, monkeypatch, small_weights
):
    """No GPU → the runtime already IS the guaranteed baseline; a selftest
    failure is final (no reinstall to retry with)."""
    monkeypatch.setattr(summarizer_env, "probe_gpu_visible", lambda: False)
    runner = RecordingRunner(fail_verify_times=2)

    with pytest.raises(summarizer_env.InstallError):
        summarizer_env.install(runner=runner)

    assert [s.phase for s in runner.steps] == ["venv", "runtime", "weights", "verify"]


def test_weights_size_verification_uses_the_real_floor(temp_data_dir, monkeypatch):
    """A sparse file JUST over the real 2.4 GB floor passes verification.

    Uses the REAL MIN_MODEL_BYTES (no small_weights fixture): NTFS creates
    the sparse file in ~2 s without writing gigabytes.
    """
    monkeypatch.setattr(summarizer_env, "probe_gpu_visible", lambda: False)
    assert summarizer_env.MIN_MODEL_BYTES == 2_400_000_000
    summarizer_env.install(runner=RecordingRunner())
    gguf = summarizer_env.env_dir() / "models" / summarize_infer.MODEL_FILENAME
    assert gguf.stat().st_size > summarizer_env.MIN_MODEL_BYTES


def test_truncated_weights_download_fails_the_install(temp_data_dir, monkeypatch):
    """A too-small GGUF (interrupted download, HTML error page saved as the
    file) must fail the weights phase — real floor, no fixture."""
    monkeypatch.setattr(summarizer_env, "probe_gpu_visible", lambda: False)
    runner = RecordingRunner(weights_size=1_000_000)
    with pytest.raises(summarizer_env.InstallError):
        summarizer_env.install(runner=runner)
    assert [s.phase for s in runner.steps] == ["venv", "runtime", "weights"], (
        "verify must never run against a truncated model"
    )
    assert not summarizer_env.env_dir().exists()
    assert not summarizer_env.tmp_env_dir().exists()
    prog = summarizer_env.progress()
    assert prog["phase"] == "failed"
    assert "weights" in prog["detail"]


def test_gpu_visible_attempts_cuda_then_falls_back_to_cpu(temp_data_dir, monkeypatch, small_weights):
    monkeypatch.setattr(summarizer_env, "probe_gpu_visible", lambda: True)
    runner = RecordingRunner(fail_argv_containing=summarizer_env.CUDA_WHEEL_INDEX)
    summarizer_env.install(runner=runner)  # must NOT raise — CPU fallback

    runtime_steps = [s for s in runner.steps if s.phase == "runtime"]
    assert len(runtime_steps) == 2, "CUDA attempt then CPU fallback"
    assert any(summarizer_env.CUDA_WHEEL_INDEX in a for a in runtime_steps[0].argv)
    assert any(summarizer_env.CPU_WHEEL_INDEX in a for a in runtime_steps[1].argv)
    marker = json.loads(
        (summarizer_env.env_dir() / "verified.json").read_text(encoding="utf-8")
    )
    assert marker["runtime"] == "cpu"
    assert summarizer_env.progress()["phase"] == "done"


def test_cuda_install_also_installs_vendored_cuda_runtime_packages(
    temp_data_dir, monkeypatch, small_weights
):
    """The container ships no CUDA runtime — the cu124 wheel needs libcudart
    AND libcublas, so the CUDA pip step must vendor both nvidia wheels into
    the venv (the live-E2E failure: libcudart.so.12 not found)."""
    monkeypatch.setattr(summarizer_env, "probe_gpu_visible", lambda: True)
    runner = RecordingRunner()
    summarizer_env.install(runner=runner)

    cuda_step = next(
        s
        for s in runner.steps
        if s.phase == "runtime" and any(summarizer_env.CUDA_WHEEL_INDEX in a for a in s.argv)
    )
    for pkg in ("nvidia-cuda-runtime-cu12", "nvidia-cublas-cu12"):
        assert pkg in cuda_step.argv, f"CUDA install must also pip-install {pkg}"


def test_cpu_install_never_installs_cuda_runtime_packages(
    temp_data_dir, monkeypatch, small_weights
):
    monkeypatch.setattr(summarizer_env, "probe_gpu_visible", lambda: False)
    runner = RecordingRunner()
    summarizer_env.install(runner=runner)
    for step in runner.steps:
        assert not any("nvidia-" in a for a in step.argv), (
            "CPU installs must not drag in CUDA runtime wheels"
        )


def test_gpu_visible_cuda_success_records_cuda_runtime(temp_data_dir, monkeypatch, small_weights):
    monkeypatch.setattr(summarizer_env, "probe_gpu_visible", lambda: True)
    runner = RecordingRunner()
    summarizer_env.install(runner=runner)

    runtime_steps = [s for s in runner.steps if s.phase == "runtime"]
    assert len(runtime_steps) == 1
    assert any(summarizer_env.CUDA_WHEEL_INDEX in a for a in runtime_steps[0].argv)
    marker = json.loads(
        (summarizer_env.env_dir() / "verified.json").read_text(encoding="utf-8")
    )
    assert marker["runtime"] == "cuda"
    cap = summarizer_env.capability()
    assert cap["installed"] is True
    assert cap["runtime"] == "cuda"


def test_no_gpu_never_attempts_cuda_wheel(temp_data_dir, monkeypatch, small_weights):
    monkeypatch.setattr(summarizer_env, "probe_gpu_visible", lambda: False)
    runner = RecordingRunner()
    summarizer_env.install(runner=runner)
    for step in runner.steps:
        assert not any(summarizer_env.CUDA_WHEEL_INDEX in a for a in step.argv)


def test_verify_step_runs_selftest_with_tmp_python_and_tmp_model_path(
    temp_data_dir, monkeypatch, small_weights
):
    monkeypatch.setattr(summarizer_env, "probe_gpu_visible", lambda: False)
    runner = RecordingRunner()
    summarizer_env.install(runner=runner)
    verify = next(s for s in runner.steps if s.phase == "verify")

    assert "summarizer-env.tmp" in verify.argv[0], "verify runs the TMP venv python"
    assert verify.argv[1].endswith("summarize_infer.py")
    assert "--selftest" in verify.argv
    model_path = verify.argv[verify.argv.index("--model-path") + 1]
    assert "summarizer-env.tmp" in model_path, (
        "selftest must target the tmp GGUF — the env is not published yet"
    )
    assert model_path.endswith(summarize_infer.MODEL_FILENAME)

    weights = next(s for s in runner.steps if s.phase == "weights")
    assert weights.kind == "download"
    assert weights.repo_id == summarizer_env.GGUF_REPO_ID
    assert weights.filename == summarize_infer.MODEL_FILENAME


def test_second_install_while_running_raises_conflict(temp_data_dir, monkeypatch, small_weights):
    monkeypatch.setattr(summarizer_env, "probe_gpu_visible", lambda: False)
    release = threading.Event()
    runner = RecordingRunner(block=release)
    thread = summarizer_env.start_install(runner=runner)
    try:
        with pytest.raises(summarizer_env.InstallInProgress):
            summarizer_env.install(runner=RecordingRunner())
        assert summarizer_env.install_running()
    finally:
        release.set()
        thread.join(timeout=10)
    _wait_not_running()
    assert summarizer_env.progress()["phase"] == "done"


def test_python_path_none_until_verified_install(temp_data_dir, monkeypatch, small_weights):
    monkeypatch.setattr(summarizer_env, "probe_gpu_visible", lambda: False)
    assert summarizer_env.python_path() is None
    summarizer_env.install(runner=RecordingRunner())
    p = summarizer_env.python_path()
    assert p is not None
    path = Path(p)
    assert path.exists()
    assert "summarizer-env" in path.parts
    assert "venv" in path.parts


def test_capability_truth_table(temp_data_dir, monkeypatch, small_weights):
    monkeypatch.setattr(summarizer_env, "probe_gpu_visible", lambda: False)
    cap = summarizer_env.capability()
    assert cap["installed"] is False
    assert cap["runtime"] is None
    assert cap["gpu_visible"] is False
    assert cap["install_running"] is False
    assert isinstance(cap["disk_free_bytes"], int)
    assert cap["disk_free_bytes"] > 0

    summarizer_env.install(runner=RecordingRunner())
    cap = summarizer_env.capability()
    assert cap["installed"] is True
    assert cap["runtime"] == "cpu"


def test_capability_dir_without_verify_marker_is_not_installed(temp_data_dir):
    summarizer_env.env_dir().mkdir(parents=True)
    cap = summarizer_env.capability()
    assert cap["installed"] is False
    assert cap["runtime"] is None


def test_uninstall_removes_env_and_stale_tmp_keeps_nothing_else(
    temp_data_dir, monkeypatch, small_weights
):
    """Uninstall deletes the env (and crashed-install debris). It takes no
    db handle at all — stored dump summaries are user data and survive by
    construction (the wizard promise: env deleted, summaries KEPT)."""
    monkeypatch.setattr(summarizer_env, "probe_gpu_visible", lambda: False)
    summarizer_env.install(runner=RecordingRunner())
    stale_tmp = summarizer_env.tmp_env_dir()
    stale_tmp.mkdir(parents=True)
    (stale_tmp / "leftover.txt").write_text("crashed install debris", encoding="utf-8")

    assert summarizer_env.uninstall() is True

    assert not summarizer_env.env_dir().exists()
    assert not summarizer_env.tmp_env_dir().exists()
    assert summarizer_env.python_path() is None
    assert summarizer_env.capability()["installed"] is False
    assert summarizer_env.progress() == {"phase": "idle", "percent": 0, "detail": ""}


def test_uninstall_conflict_while_install_running(temp_data_dir, monkeypatch, small_weights):
    monkeypatch.setattr(summarizer_env, "probe_gpu_visible", lambda: False)
    release = threading.Event()
    runner = RecordingRunner(block=release)
    thread = summarizer_env.start_install(runner=runner)
    try:
        with pytest.raises(summarizer_env.InstallInProgress):
            summarizer_env.uninstall()
    finally:
        release.set()
        thread.join(timeout=10)
    _wait_not_running()


def test_on_installed_hook_fires_after_publish(temp_data_dir, monkeypatch, small_weights):
    monkeypatch.setattr(summarizer_env, "probe_gpu_visible", lambda: False)
    seen: list[bool] = []
    summarizer_env.set_on_installed(
        lambda: seen.append(summarizer_env.env_dir().exists())
    )
    summarizer_env.install(runner=RecordingRunner())
    assert seen == [True], "hook must fire once, after the env dir is published"


def test_infer_script_exists_at_the_path_the_installer_verifies():
    assert summarizer_env._summarize_infer_path().exists()
    assert (
        Path(summarize_infer.__file__).resolve()
        == summarizer_env._summarize_infer_path().resolve()
    )


# ---------------------------------------------------------------------------
# summarizer_env: child_env (LD_LIBRARY_PATH for pip-vendored CUDA libs)
# ---------------------------------------------------------------------------
#
# The live-container failure this guards: the cu124 llama-cpp wheel links
# libcudart.so.12/libcublas, but the tangent-server image ships NO CUDA
# runtime (whisper works only because ctranslate2 vendors its own libs).
# The venv carries nvidia-cuda-runtime-cu12 + nvidia-cublas-cu12 instead,
# and every child process (installer selftest AND worker serve child) needs
# LD_LIBRARY_PATH pointing at those vendored lib dirs.


def _make_nvidia_libs(venv: Path) -> list[Path]:
    """Create the pip-vendored nvidia lib layout under a fake venv."""
    site = venv / "lib" / "python3.11" / "site-packages" / "nvidia"
    dirs = [site / "cuda_runtime" / "lib", site / "cublas" / "lib"]
    for d in dirs:
        d.mkdir(parents=True)
    return dirs


def test_child_env_prepends_nvidia_lib_dirs_to_existing_ld_library_path(
    tmp_path, monkeypatch
):
    venv = tmp_path / "venv"
    lib_dirs = _make_nvidia_libs(venv)
    (venv / "bin").mkdir()
    py = venv / "bin" / "python"
    py.write_text("")
    monkeypatch.setenv("LD_LIBRARY_PATH", "/existing/libs")

    env = summarizer_env.child_env(str(py))

    parts = env["LD_LIBRARY_PATH"].split(os.pathsep)
    assert parts[-1] == "/existing/libs", "existing LD_LIBRARY_PATH must survive, last"
    assert sorted(parts[:-1]) == sorted(str(d) for d in lib_dirs), (
        "every vendored nvidia lib dir must be prepended"
    )


def test_child_env_survives_a_symlinked_venv_python(tmp_path):
    """The real venv's bin/python is a SYMLINK to the system interpreter.

    Path.resolve() would follow it OUT of the venv and the nvidia glob would
    silently find nothing — the exact live-container failure mode. child_env
    must derive the venv root from the literal path it was given.
    """
    venv = tmp_path / "venv"
    lib_dirs = _make_nvidia_libs(venv)
    (venv / "bin").mkdir()
    real = tmp_path / "system-python"
    real.write_text("")
    py = venv / "bin" / "python"
    try:
        py.symlink_to(real)
    except OSError:
        pytest.skip("symlinks unavailable on this bench (Windows non-dev-mode); Linux CI is authority")

    env = summarizer_env.child_env(str(py))

    assert "LD_LIBRARY_PATH" in env, "symlinked python must still find the venv's nvidia dirs"
    parts = env["LD_LIBRARY_PATH"].split(os.pathsep)
    assert sorted(str(d) for d in lib_dirs) == sorted(
        p for p in parts if "nvidia" in p
    ), "vendored lib dirs must come from the venv, not the resolved system path"


def test_child_env_without_nvidia_dirs_leaves_ld_library_path_alone(
    tmp_path, monkeypatch
):
    venv = tmp_path / "venv"
    (venv / "bin").mkdir(parents=True)
    py = venv / "bin" / "python"
    py.write_text("")
    monkeypatch.delenv("LD_LIBRARY_PATH", raising=False)

    env = summarizer_env.child_env(str(py))

    assert "LD_LIBRARY_PATH" not in env, "a CPU env must not invent LD_LIBRARY_PATH"
    assert env["PATH"] == os.environ["PATH"], "the rest of the environment passes through"


def test_default_runner_gives_the_selftest_child_env(tmp_path, monkeypatch):
    """The verify step must run under child_env — otherwise the selftest
    can't see the venv's vendored CUDA libs (the live-E2E failure)."""
    tmp = tmp_path / "summarizer-env.tmp"
    venv = tmp / "venv"
    lib = venv / "lib" / "python3.11" / "site-packages" / "nvidia" / "cuda_runtime" / "lib"
    lib.mkdir(parents=True)

    recorded: dict = {}

    def fake_run(argv, **kwargs):
        recorded["argv"] = argv
        recorded["env"] = kwargs.get("env")

        class Proc:
            returncode = 0
            stdout = ""
            stderr = ""

        return Proc()

    monkeypatch.setattr(summarizer_env.subprocess, "run", fake_run)
    summarizer_env.default_runner(summarizer_env._verify_step(tmp))

    assert recorded["env"] is not None, "selftest must not inherit the bare server env"
    assert str(lib) in recorded["env"]["LD_LIBRARY_PATH"].split(os.pathsep)
