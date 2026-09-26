# SPDX-License-Identifier: AGPL-3.0-or-later
"""Standalone Qwen summarization script — runs in the summarizer venv.

This file is executed by ``summarizer_env.python_path()`` (the venv the
installer built), NEVER imported *for inference* by the server process:
llama-cpp stays out of the server's memory. The server MAY import this
module for its constants (model filename, system prompt) — everything heavy
is imported inside functions that only run under the summarizer venv. It
must not import anything from ``app``: the venv has no access to the
server's packages, only to its own site-packages and this file's path.

Modes:
  --serve              Load the model ONCE, then read one JSON object per
                       line from stdin ({"id": ..., "transcript": ...,
                       "system_prompt": ...}) and
                       write exactly one JSON result line per input
                       ({"id": ..., "summary": ...} or {"id": ..., "error":
                       ...}), flushed immediately. EOF on stdin exits
                       cleanly. This is the worker's persistent-child
                       protocol — one model load per child lifetime.
  --selftest           Run one real tiny inference and assert the summary is
                       non-empty. The installer's verify step runs this
                       before an install is published.
  --model-path <path>  Override the GGUF location (default: derived from the
                       interpreter's own location, <env>/models/<gguf>).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

try:  # Package import in server/tests; sibling import when executed as a script.
    from .summary_templates import MEETING_PROMPT
except ImportError:  # pragma: no cover - exercised by the real child process
    from summary_templates import MEETING_PROMPT

# Bartowski mirror filename (the official Qwen repo is 401-gated).
MODEL_FILENAME = "Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf"

# Sampling parameters — validated in the Task 0 prompt bake-off (binding).
TEMPERATURE = 0.2
MAX_TOKENS = 1024
CTX_TOKENS = 8192

# Backward-compatible alias for existing imports. The preset module is now the
# single source of truth, and its drift-guard test pins the full former value.
SYSTEM_PROMPT = MEETING_PROMPT

# A placeholder line the model emits for an empty section ("None", "- None",
# "None identified.", ...). Sections containing ONLY these are stripped.
_NONE_LINE = re.compile(r"^-?\s*None\b.*$", re.IGNORECASE)
_HEADING = re.compile(r"^##\s+\S")

# Transcript for --selftest: tiny but real — one decision, one action item.
SELFTEST_TRANSCRIPT = """\
Sam: Should we move the standup to 9am?
Lee: Yes, 9am works better for everyone. Let's switch starting Monday.
Sam: OK, I'll update the calendar invite today.
"""


def default_model_path(python_path: str | None = None) -> Path:
    """The GGUF path for the venv that owns ``python_path``.

    The installer lays the env out as ``<env>/venv/{Scripts,bin}/python`` and
    ``<env>/models/<gguf>``; three levels up from the interpreter is <env>.
    """
    py = Path(python_path if python_path is not None else sys.executable)
    return py.parent.parent.parent / "models" / MODEL_FILENAME


def postprocess(text: str) -> str:
    """Strip empty sections from the model's output (binding template rule).

    The prompt tells the validated model to write "None" under a heading with
    no items; the stored summary must instead OMIT that section. A section is
    dropped when every non-blank line of its body matches the placeholder
    pattern — which also covers a trailing standalone heading with no body.
    Text before the first heading and sections with any real content are kept
    byte-for-byte (bodies lose only trailing blank lines; kept sections are
    re-joined with a single blank line, matching the template).
    """
    lines = text.split("\n")
    preamble: list[str] = []
    sections: list[tuple[str, list[str]]] = []
    current: list[str] | None = None
    for line in lines:
        if _HEADING.match(line):
            current = []
            sections.append((line, current))
        elif current is None:
            preamble.append(line)
        else:
            current.append(line)

    parts: list[str] = []
    pre = "\n".join(preamble).strip()
    if pre:
        parts.append(pre)
    for heading, body in sections:
        while body and not body[-1].strip():
            body.pop()
        content = [ln for ln in body if ln.strip()]
        if not content or all(_NONE_LINE.match(ln.strip()) for ln in content):
            continue
        parts.append(heading + "\n" + "\n".join(body))
    return "\n\n".join(parts)


def _gpu_layers() -> int:
    """How many layers to offload. CPU and GPU produce IDENTICAL output —
    the wheel the installer picked decides whether offload is even possible;
    TANGENT_SUMMARIZER_DEVICE=cpu forces CPU on a CUDA wheel."""
    override = os.environ.get("TANGENT_SUMMARIZER_DEVICE", "").strip().lower()
    return 0 if override == "cpu" else -1


def _load_llm(model_path: Path):
    """Load the GGUF once. llama_cpp exists only in the summarizer venv."""
    from llama_cpp import Llama

    return Llama(
        model_path=str(model_path),
        n_ctx=CTX_TOKENS,
        n_gpu_layers=_gpu_layers(),
        verbose=False,
    )


def _summarize_loaded(llm, transcript: str, system_prompt: str) -> str:
    """One transcript through an already-loaded model, post-processed."""
    resp = llm.create_chat_completion(
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": transcript},
        ],
        temperature=TEMPERATURE,
        max_tokens=MAX_TOKENS,
    )
    content = resp["choices"][0]["message"]["content"] or ""
    return postprocess(content.strip())


def serve(model_path: Path) -> int:
    """Persistent line protocol: one JSON request in, one JSON result out.

    The model is loaded exactly once. Per-request failures (bad JSON, missing
    transcript, model error) are reported as {"id": ..., "error": ...} on
    stdout — the process keeps serving. EOF on stdin is clean shutdown.
    """
    for stream in (sys.stdin, sys.stdout):
        try:
            stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass  # non-reconfigurable stream (redirected/test harness)

    llm = _load_llm(model_path)
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        req_id = ""
        try:
            req = json.loads(line)
            req_id = str(req.get("id", "")) if isinstance(req, dict) else ""
            if not isinstance(req, dict):
                raise ValueError("request must be a JSON object")
            transcript = req.get("transcript")
            if not isinstance(transcript, str) or not transcript.strip():
                raise ValueError("request has no non-empty 'transcript'")
            system_prompt = req.get("system_prompt")
            if not isinstance(system_prompt, str) or not system_prompt.strip():
                raise ValueError("request has no non-empty 'system_prompt'")
            out = {
                "id": req_id,
                "summary": _summarize_loaded(llm, transcript, system_prompt),
            }
        except Exception as exc:  # noqa: BLE001 — one bad line must not kill the server
            out = {"id": req_id, "error": f"{type(exc).__name__}: {exc}"}
        print(json.dumps(out), flush=True)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Qwen meeting summarization")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--serve",
        action="store_true",
        help="persistent mode: JSON requests on stdin, JSON results on stdout",
    )
    group.add_argument(
        "--selftest",
        action="store_true",
        help="run one tiny real inference and assert the summary is non-empty",
    )
    parser.add_argument("--model-path", default=None)
    args = parser.parse_args(argv)

    model_path = Path(args.model_path) if args.model_path else default_model_path()

    if args.serve:
        return serve(model_path)

    llm = _load_llm(model_path)
    summary = _summarize_loaded(llm, SELFTEST_TRANSCRIPT, MEETING_PROMPT)
    if not summary:
        print("selftest failed: model returned an empty summary", file=sys.stderr)
        return 1
    print(summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
