# SPDX-License-Identifier: AGPL-3.0-or-later
"""Boot-path third-party imports must be DECLARED in pyproject.

Why this exists: PIL is imported at MODULE level on the boot path
(app.main → app.api.sync → app.services.ocr_worker / app.services.ink_render),
but pillow was once missing from [project.dependencies]. The test venv MASKED
it — its packages were hand-installed — while a container built from the
Dockerfile (`uv pip install .`) failed with ModuleNotFoundError on every boot.
These tests read pyproject.toml directly, so no venv contents can hide a
missing declaration again.
"""

from __future__ import annotations

import ast
import re
import sys
import tomllib
from importlib.metadata import packages_distributions
from pathlib import Path

SERVER_ROOT = Path(__file__).resolve().parent.parent

#: Modules whose module-level imports run on EVERY boot (app.main →
#: app.api.sync imports ocr_worker, which imports ink_render) yet whose
#: heavyweight deps are easy to assume "the on-demand OCR venv provides".
#: It does not: these modules import in the BASE server env.
BOOT_PATH_MODULES = (
    SERVER_ROOT / "app" / "services" / "ocr_worker.py",
    SERVER_ROOT / "app" / "services" / "ink_render.py",
)


def _normalize(name: str) -> str:
    """PEP 503 distribution-name normalization (Pillow == pillow)."""
    return re.sub(r"[-_.]+", "-", name).lower()


def _declared_dependencies() -> set[str]:
    data = tomllib.loads((SERVER_ROOT / "pyproject.toml").read_text("utf-8"))
    declared: set[str] = set()
    for req in data["project"]["dependencies"]:
        match = re.match(r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)", req)
        assert match, f"unparseable requirement in pyproject: {req!r}"
        declared.add(_normalize(match.group(1)))
    return declared


def _module_level_imports(path: Path) -> set[str]:
    """Root packages imported at MODULE scope (the ones that run at boot)."""
    tree = ast.parse(path.read_text("utf-8"))
    roots: set[str] = set()
    for node in tree.body:
        if isinstance(node, ast.Import):
            roots.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
            roots.add(node.module.split(".")[0])
    return roots


def test_pillow_is_declared_in_project_dependencies():
    # PIL is imported at module level on the boot path; without this line in
    # [project.dependencies] every container boot dies at import time.
    assert "pillow" in _declared_dependencies(), (
        "pillow must be declared in [project.dependencies]: PIL is imported "
        "at module level by app.services.ocr_worker and app.services."
        "ink_render, both reached from app.main via app.api.sync"
    )


def test_boot_path_module_level_imports_are_all_declared():
    """Every top-level import in the OCR boot-path modules is stdlib, local,
    or provided by a distribution named in [project.dependencies]."""
    declared = _declared_dependencies()
    module_to_dists = packages_distributions()
    for path in BOOT_PATH_MODULES:
        for root in sorted(_module_level_imports(path)):
            if root in sys.stdlib_module_names or root == "app":
                continue
            dists = [_normalize(d) for d in module_to_dists.get(root, [])]
            assert dists, (
                f"{path.name} imports {root!r} at module level but no "
                "installed distribution provides it — declare it in pyproject"
            )
            assert set(dists) & declared, (
                f"{path.name} imports {root!r} at module level (boot path), "
                f"provided by {dists}, none of which appear in "
                "[project.dependencies]. The .venv-test masks this because "
                "its packages were hand-installed; a container built from "
                "pyproject alone fails at import time on every boot."
            )
