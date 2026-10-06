#!/usr/bin/env python3
"""Audit Tangent's four F-Droid release APKs.

Usage:
  python tool/audit_android_release.py \
    universal=build/app/outputs/flutter-apk/app-release.apk \
    armeabi-v7a=... arm64-v8a=... x86_64=...
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile

EXPECTED_ABIS = {
    "universal": {"armeabi-v7a", "arm64-v8a", "x86_64"},
    "armeabi-v7a": {"armeabi-v7a"},
    "arm64-v8a": {"arm64-v8a"},
    "x86_64": {"x86_64"},
}
EXPECTED_VERSION_CODES = {
    "universal": "70",
    "armeabi-v7a": "701",
    "arm64-v8a": "702",
    "x86_64": "703",
}
SQLITE_VERSION = b"3.50.2"
SQLITE_SOURCE_ID = b"2025-06-28 14:00:48 2af157d7"
FORBIDDEN_PATHS = (b".worktrees", b"ADH2", b"fdroid-review-followups")


def run(*args: str) -> str:
    process = subprocess.run(args, check=False, capture_output=True, text=True)
    if process.returncode:
        raise RuntimeError(f"{' '.join(args)} failed: {process.stdout}{process.stderr}")
    return process.stdout + process.stderr


def find_tool(sdk: Path, ndk: str, name: str) -> Path:
    suffix = ".exe" if os.name == "nt" else ""
    candidates = list((sdk / "ndk" / ndk / "toolchains" / "llvm" / "prebuilt").glob(f"*/bin/{name}{suffix}"))
    if not candidates:
        raise FileNotFoundError(f"{name} not found under NDK {ndk}")
    return candidates[0]


def audit(
    label: str,
    apk: Path,
    *,
    readelf: Path,
    apksigner: Path,
    aapt: Path,
) -> dict[str, object]:
    expected = EXPECTED_ABIS[label]
    raw = apk.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    certs = run(str(apksigner), "verify", "--verbose", "--print-certs", str(apk))
    if "CN=Tangent" not in certs:
        raise AssertionError(f"{apk}: signer is not CN=Tangent")
    cert_match = re.search(
        r"Signer #1 certificate SHA-256 digest: ([0-9a-f]+)", certs
    )
    if not cert_match:
        raise AssertionError(f"{apk}: certificate SHA-256 digest unavailable")
    badging = run(str(aapt), "dump", "badging", str(apk))
    package = re.search(
        r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'",
        badging,
    )
    expected_package = (
        "dev.tangent.tangent",
        EXPECTED_VERSION_CODES[label],
        "1.50.1",
    )
    if package is None or package.groups() != expected_package:
        raise AssertionError(
            f"{apk}: unexpected package metadata "
            f"{None if package is None else package.groups()}"
        )

    sqlite_entries: dict[str, bytes] = {}
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        forbidden_assets = [
            name for name in names
            if "pdfium" in name.lower()
            or "pdfrx_engine" in name.lower()
            or name.lower().endswith(".wasm")
        ]
        if forbidden_assets:
            raise AssertionError(f"{apk}: forbidden PDFium/web assets: {forbidden_assets}")
        for name in names:
            match = re.fullmatch(r"lib/([^/]+)/libsqlite3\.so", name)
            if match:
                sqlite_entries[match.group(1)] = archive.read(name)
        actual = set(sqlite_entries)
        if actual != expected:
            raise AssertionError(f"{apk}: SQLite ABIs {sorted(actual)}, expected {sorted(expected)}")

        native_names = [name for name in names if name.endswith(".so")]
        path_leaks: list[str] = []
        with tempfile.TemporaryDirectory(prefix="tangent-apk-audit-") as temporary:
            root = Path(temporary)
            for name in native_names:
                data = archive.read(name)
                if any(token in data for token in FORBIDDEN_PATHS):
                    path_leaks.append(name)
                target = root / name.replace("/", "_")
                target.write_bytes(data)
                sections = run(str(readelf), "--sections", str(target))
                if ".note.gnu.build-id" in sections:
                    raise AssertionError(f"{apk}:{name}: .note.gnu.build-id survived")

            for abi, data in sqlite_entries.items():
                if SQLITE_VERSION not in data or SQLITE_SOURCE_ID not in data:
                    raise AssertionError(f"{apk}:lib/{abi}/libsqlite3.so: wrong SQLite source/version")
                if b"ENABLE_FTS5" not in data:
                    raise AssertionError(f"{apk}:lib/{abi}/libsqlite3.so: FTS5 is not enabled")
                target = root / f"sqlite-{abi}.so"
                target.write_bytes(data)
                symbols = run(str(readelf), "--dyn-syms", "--wide", str(target))
                for symbol in ("sqlite3_open", "sqlite3_compileoption_used"):
                    if symbol not in symbols:
                        raise AssertionError(f"{apk}:lib/{abi}/libsqlite3.so: missing {symbol}")

    return {
        "label": label,
        "path": str(apk.resolve()),
        "sha256": digest,
        "size": len(raw),
        "abis": sorted(sqlite_entries),
        "signed_by": "CN=Tangent",
        "certificate_sha256": cert_match.group(1),
        "version_code": package.group(2),
        "version_name": package.group(3),
        "pdfium_or_wasm_assets": 0,
        "build_id_sections": 0,
        "path_leaks": path_leaks,
        "sqlite": "3.50.2 / FTS5",
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("artifacts", nargs=4, metavar="LABEL=APK")
    parser.add_argument("--sdk", type=Path, default=Path(os.environ.get("ANDROID_HOME", Path.home() / "AppData/Local/Android/Sdk")))
    parser.add_argument("--ndk", default="28.2.13676358")
    args = parser.parse_args()
    pairs = dict(item.split("=", 1) for item in args.artifacts)
    if set(pairs) != set(EXPECTED_ABIS):
        parser.error(f"labels must be: {', '.join(EXPECTED_ABIS)}")
    readelf = find_tool(args.sdk, args.ndk, "llvm-readelf")
    apksigner = args.sdk / "build-tools" / "36.0.0" / ("apksigner.bat" if os.name == "nt" else "apksigner")
    if not apksigner.exists():
        matches = sorted((args.sdk / "build-tools").glob("*/apksigner.bat" if os.name == "nt" else "*/apksigner"))
        if not matches:
            raise FileNotFoundError("apksigner not found")
        apksigner = matches[-1]
    aapt = apksigner.with_name("aapt.exe" if os.name == "nt" else "aapt")
    report = [
        audit(
            label,
            Path(pairs[label]),
            readelf=readelf,
            apksigner=apksigner,
            aapt=aapt,
        )
        for label in EXPECTED_ABIS
    ]
    print(json.dumps({"ndk": args.ndk, "artifacts": report}, indent=2))


if __name__ == "__main__":
    main()
