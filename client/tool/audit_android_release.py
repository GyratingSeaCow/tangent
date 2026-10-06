#!/usr/bin/env python3
"""Audit Tangent Android release APKs.

Usage:
  python tool/audit_android_release.py universal=app-release.apk
  python tool/audit_android_release.py \
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
ABI_VERSION_CODE_DIGITS = {
    "armeabi-v7a": 1,
    "arm64-v8a": 2,
    "x86_64": 3,
}
EXPECTED_NDK_VERSION = "28.2.13676358"
EXPECTED_CLANG_VERSION = "19.0.1"
EXPECTED_NDK_REVISION = "r530567e"
EXPECTED_LINKER_IDENTITY = "Linker: LLD 19.0.1"
SQLITE_VERSION = b"3.50.2"
SQLITE_SOURCE_ID = b"2025-06-28 14:00:48 2af157d7"
FORBIDDEN_PATHS = (b".worktrees", b"ADH2", b"fdroid-review-followups")
ASCII_STRING = re.compile(rb"[ -~]{8,}")


def release_version(pubspec: Path) -> tuple[str, int]:
    matches = re.findall(
        r"^version:\s*([^+\s#]+)\+([0-9]+)\s*(?:#.*)?$",
        pubspec.read_text(encoding="utf-8"),
        flags=re.MULTILINE,
    )
    if len(matches) != 1:
        raise ValueError(f"{pubspec}: expected one version: <name>+<integer> entry")
    version_name, base_code = matches[0]
    return version_name, int(base_code)


def expected_version_codes(base_code: int) -> dict[str, str]:
    return {
        "universal": str(base_code),
        **{
            abi: str(base_code * 10 + digit)
            for abi, digit in ABI_VERSION_CODE_DIGITS.items()
        },
    }


def toolchain_identities(binary: bytes) -> dict[str, list[str]]:
    strings = [value.decode("ascii") for value in ASCII_STRING.findall(binary)]
    return {
        "compiler": sorted({value for value in strings if "clang version " in value}),
        "linker": sorted({value for value in strings if value.startswith("Linker: ")}),
    }


def require_expected_toolchain(binary: bytes, source: str) -> dict[str, list[str]]:
    identities = toolchain_identities(binary)
    compilers = identities["compiler"]
    linkers = identities["linker"]
    if not compilers:
        raise AssertionError(f"{source}: compiler identity unavailable")
    expected_clang = f"clang version {EXPECTED_CLANG_VERSION}"
    unexpected = [
        identity
        for identity in compilers
        if expected_clang not in identity or EXPECTED_NDK_REVISION not in identity
    ]
    if unexpected:
        raise AssertionError(
            f"{source}: expected NDK {EXPECTED_NDK_VERSION} "
            f"({expected_clang}, {EXPECTED_NDK_REVISION}); found {unexpected}"
        )
    if not linkers:
        raise AssertionError(f"{source}: linker identity unavailable")
    unexpected_linkers = [
        identity for identity in linkers if identity != EXPECTED_LINKER_IDENTITY
    ]
    if unexpected_linkers:
        raise AssertionError(
            f"{source}: expected {EXPECTED_LINKER_IDENTITY}; "
            f"found {unexpected_linkers}"
        )
    return identities


def run(*args: str) -> str:
    process = subprocess.run(args, check=False, capture_output=True, text=True)
    if process.returncode:
        raise RuntimeError(f"{' '.join(args)} failed: {process.stdout}{process.stderr}")
    return process.stdout + process.stderr


def find_tool(sdk: Path, ndk: str, name: str) -> Path:
    suffix = ".exe" if os.name == "nt" else ""
    candidates = list(
        (sdk / "ndk" / ndk / "toolchains" / "llvm" / "prebuilt").glob(
            f"*/bin/{name}{suffix}"
        )
    )
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
    version_name: str,
    version_codes: dict[str, str],
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
        version_codes[label],
        version_name,
    )
    if package is None or package.groups() != expected_package:
        raise AssertionError(
            f"{apk}: unexpected package metadata "
            f"{None if package is None else package.groups()}, expected {expected_package}"
        )

    sqlite_entries: dict[str, bytes] = {}
    sqlite_toolchains: dict[str, dict[str, list[str]]] = {}
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        forbidden_assets = [
            name
            for name in names
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
            raise AssertionError(
                f"{apk}: SQLite ABIs {sorted(actual)}, expected {sorted(expected)}"
            )

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
                    raise AssertionError(
                        f"{apk}:lib/{abi}/libsqlite3.so: wrong SQLite source/version"
                    )
                if b"ENABLE_FTS5" not in data:
                    raise AssertionError(
                        f"{apk}:lib/{abi}/libsqlite3.so: FTS5 is not enabled"
                    )
                source = f"{apk}:lib/{abi}/libsqlite3.so"
                sqlite_toolchains[abi] = require_expected_toolchain(data, source)
                target = root / f"sqlite-{abi}.so"
                target.write_bytes(data)
                symbols = run(str(readelf), "--dyn-syms", "--wide", str(target))
                for symbol in ("sqlite3_open", "sqlite3_compileoption_used"):
                    if symbol not in symbols:
                        raise AssertionError(f"{source}: missing {symbol}")

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
        "sqlite_toolchains": sqlite_toolchains,
        "sqlite_ndk": EXPECTED_NDK_VERSION,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("artifacts", nargs="+", metavar="LABEL=APK")
    parser.add_argument(
        "--sdk",
        type=Path,
        default=Path(
            os.environ.get("ANDROID_HOME", Path.home() / "AppData/Local/Android/Sdk")
        ),
    )
    parser.add_argument("--ndk", default=EXPECTED_NDK_VERSION)
    parser.add_argument(
        "--pubspec",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "pubspec.yaml",
    )
    args = parser.parse_args()
    if args.ndk != EXPECTED_NDK_VERSION:
        parser.error(f"--ndk must be {EXPECTED_NDK_VERSION}")
    parsed = [item.split("=", 1) for item in args.artifacts]
    if any(len(item) != 2 or not item[0] or not item[1] for item in parsed):
        parser.error("artifacts must use LABEL=APK")
    labels = [item[0] for item in parsed]
    if len(labels) != len(set(labels)):
        parser.error("artifact labels must be unique")
    unknown = set(labels) - set(EXPECTED_ABIS)
    if unknown:
        parser.error(f"unknown labels: {', '.join(sorted(unknown))}")
    pairs = dict(parsed)

    version_name, base_code = release_version(args.pubspec)
    version_codes = expected_version_codes(base_code)
    readelf = find_tool(args.sdk, args.ndk, "llvm-readelf")
    apksigner = args.sdk / "build-tools" / "36.0.0" / (
        "apksigner.bat" if os.name == "nt" else "apksigner"
    )
    if not apksigner.exists():
        matches = sorted(
            (args.sdk / "build-tools").glob(
                "*/apksigner.bat" if os.name == "nt" else "*/apksigner"
            )
        )
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
            version_name=version_name,
            version_codes=version_codes,
        )
        for label in EXPECTED_ABIS
        if label in pairs
    ]
    print(
        json.dumps(
            {
                "ndk": args.ndk,
                "version_name": version_name,
                "base_version_code": base_code,
                "artifacts": report,
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
