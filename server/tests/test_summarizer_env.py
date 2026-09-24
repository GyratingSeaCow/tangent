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
from pathlib import Path

import pytest

from app import summarize_infer

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
