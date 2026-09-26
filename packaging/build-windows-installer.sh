# SPDX-License-Identifier: AGPL-3.0-or-later
# Builds the Windows installer from an already-built release bundle.
#
# Usage (git-bash or CI):
#   packaging/build-windows-installer.sh
#
# Deliberately does NOT run `flutter build` itself: the caller (bench or
# CI job) owns the build and its gates; this script only packages what
# exists, mirroring how build-appimage.sh consumes the Linux bundle.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
bundle="$repo_root/client/build/windows/x64/runner/Release"
iss="$repo_root/packaging/windows/tangent.iss"
out="$repo_root/packaging/windows/out"

[ -x "$bundle/tangent.exe" ] || {
  echo "no release bundle at $bundle — run 'flutter build windows --release' first" >&2
  exit 1
}

# Single source of truth for the version: pubspec.yaml (strip the +build).
version="$(sed -n 's/^version: \([0-9.]*\)+.*/\1/p' "$repo_root/client/pubspec.yaml")"
[ -n "$version" ] || { echo "could not read version from pubspec.yaml" >&2; exit 1; }

# ISCC lives in PATH on CI (choco) but not after a default local install.
iscc="$(command -v ISCC || command -v iscc || true)"
if [ -z "$iscc" ]; then
  for c in "/c/Program Files (x86)/Inno Setup 6/ISCC.exe" \
           "/c/Program Files/Inno Setup 6/ISCC.exe" \
           "$LOCALAPPDATA/Programs/Inno Setup 6/ISCC.exe"; do
    [ -x "$c" ] && { iscc="$c"; break; }
  done
fi
[ -n "$iscc" ] || { echo "Inno Setup 6 (ISCC) not found" >&2; exit 1; }

# ISCC is a native tool: give it Windows-style paths, not MSYS ones.
winpath() { echo "$1" | sed 's|^/\([a-z]\)/|\1:/|; s|/|\\|g'; }

# Git-for-Windows bash rewrites arguments that look like POSIX paths before
# a native exe sees them, so "/Qp" and "/DAppVersion=..." arrive as
# "C:/Program Files/Git/Qp" and ISCC complains "You may not specify more
# than one script filename". CI's bash.EXE has that conversion on; some
# local shells have it off. Disable it for this one call either way.
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" \
  "$iscc" /Qp "/DAppVersion=$version" "/DBundleDir=$(winpath "$bundle")" \
  "/O$(winpath "$out")" "$(winpath "$iss")"

installer="$out/tangent-setup-x64.exe"
[ -f "$installer" ] || { echo "ISCC succeeded but $installer is missing" >&2; exit 1; }
echo "built $installer ($(du -h "$installer" | cut -f1)) for version $version"
