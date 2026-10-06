#!/usr/bin/env python3
"""Unit tests for audit_android_release.py."""
from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

import audit_android_release as audit


class ReleaseVersionTest(unittest.TestCase):
    def test_reads_pubspec_and_derives_gradle_split_codes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            pubspec = Path(temporary) / "pubspec.yaml"
            pubspec.write_text(
                "name: example\nversion: 2.3.4+56\n", encoding="utf-8"
            )
            version_name, base_code = audit.release_version(pubspec)

        self.assertEqual(version_name, "2.3.4")
        self.assertEqual(base_code, 56)
        self.assertEqual(
            audit.expected_version_codes(base_code),
            {
                "universal": "56",
                "armeabi-v7a": "561",
                "arm64-v8a": "562",
                "x86_64": "563",
            },
        )

    def test_rejects_missing_flutter_build_number(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            pubspec = Path(temporary) / "pubspec.yaml"
            pubspec.write_text("version: 2.3.4\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "expected one version"):
                audit.release_version(pubspec)


class ToolchainIdentityTest(unittest.TestCase):
    def test_accepts_ndk_28_2_clang_and_lld(self) -> None:
        compiler = (
            b"Android (13624864, based on r530567e) clang version 19.0.1 "
            b"(https://android.googlesource.com/toolchain/llvm-project deadbeef)"
        )
        linker = b"Linker: LLD 19.0.1"
        self.assertEqual(
            audit.require_expected_toolchain(
                b"prefix\0" + compiler + b"\0" + linker + b"\0suffix", "fixture"
            ),
            {
                "compiler": [compiler.decode("ascii")],
                "linker": [linker.decode("ascii")],
            },
        )

    def test_rejects_ndk_27_clang(self) -> None:
        compiler = (
            b"Android (12285214, based on r522817d) clang version 18.0.3 "
            b"(https://android.googlesource.com/toolchain/llvm-project deadbeef)"
        )
        with self.assertRaisesRegex(AssertionError, "expected NDK 28.2.13676358"):
            audit.require_expected_toolchain(
                compiler + b"\0Linker: LLD 19.0.1", "fixture"
            )

    def test_rejects_version_without_ndk_revision(self) -> None:
        compiler = b"Android clang version 19.0.1"
        with self.assertRaisesRegex(AssertionError, "r530567e"):
            audit.require_expected_toolchain(
                compiler + b"\0Linker: LLD 19.0.1", "fixture"
            )

    def test_rejects_missing_linker_identity(self) -> None:
        compiler = (
            b"Android (13624864, based on r530567e) clang version 19.0.1"
        )
        with self.assertRaisesRegex(AssertionError, "linker identity unavailable"):
            audit.require_expected_toolchain(compiler, "fixture")

    def test_rejects_wrong_linker_identity(self) -> None:
        compiler = (
            b"Android (13624864, based on r530567e) clang version 19.0.1"
        )
        with self.assertRaisesRegex(AssertionError, "Linker: LLD 19.0.1"):
            audit.require_expected_toolchain(
                compiler + b"\0Linker: LLD 18.0.3", "fixture"
            )

    def test_rejects_empty_identity(self) -> None:
        with self.assertRaisesRegex(AssertionError, "compiler identity unavailable"):
            audit.require_expected_toolchain(b"", "fixture")


if __name__ == "__main__":
    unittest.main()
