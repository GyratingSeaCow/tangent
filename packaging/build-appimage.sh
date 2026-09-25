#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build Tangent-x86_64.AppImage from an existing `flutter build linux` bundle.
#
# Usage:  packaging/build-appimage.sh [path-to-bundle]
#   default bundle: client/build/linux/x64/release/bundle
#
# Requires: appimagetool (AUR `appimagetool`, or the released AppImage of it
# next to this script as `appimagetool`), and `fuse2` to RUN the result.
#
# GTK3 is assumed present on the host (every mainstream desktop distro).
# libmpv is NOT assumed: media_kit loads it at runtime with dlopen, and the
# Flutter bundle does not carry it, so we copy the system libmpv plus the
# non-baseline libs it pulls in into the AppDir and extend LD_LIBRARY_PATH
# in AppRun.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$HERE")"
BUNDLE="${1:-$REPO_ROOT/client/build/linux/x64/release/bundle}"
OUT_DIR="$HERE/out"
APPDIR="$OUT_DIR/Tangent.AppDir"

[ -x "$BUNDLE/tangent" ] || {
  echo "error: no executable at $BUNDLE/tangent — run 'flutter build linux' first" >&2
  exit 1
}

APPIMAGETOOL="$(command -v appimagetool || true)"
[ -z "$APPIMAGETOOL" ] && [ -x "$HERE/appimagetool" ] && APPIMAGETOOL="$HERE/appimagetool"
[ -n "$APPIMAGETOOL" ] || { echo "error: appimagetool not found" >&2; exit 1; }

rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/lib"

# 1. The Flutter bundle, verbatim.
cp -a "$BUNDLE/." "$APPDIR/usr/bundle/"

# 2. libmpv + its non-baseline dependency closure.
#    Baseline = glibc, GTK3 stack, X11/Wayland, systemd — present on any
#    desktop host. Everything else libmpv links against (ffmpeg, libass,
#    libplacebo, codecs...) varies wildly across distros and must ride along.
# NR trick instead of `exit`: an early awk exit SIGPIPEs ldconfig, which
# pipefail+errexit turns into a silent 141 death of the whole script.
LIBMPV="$(ldconfig -p | awk '/libmpv\.so\.2 \(/ && !found {print $NF; found=1}')"
[ -n "$LIBMPV" ] || { echo "error: system libmpv.so.2 not found" >&2; exit 1; }
cp -L "$LIBMPV" "$APPDIR/usr/lib/"
# media_kit probes dlopen("libmpv.so") before "libmpv.so.2"; on a bare host
# only the versioned file exists in our lib dir, so give the unversioned
# name too and every probe resolves inside the AppImage.
ln -sf "$(basename "$LIBMPV")" "$APPDIR/usr/lib/libmpv.so"

BASELINE_RE='^(ld-linux|linux-vdso|libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libresolv\.so|libgcc_s|libstdc\+\+|libz\.so|libglib|libgobject|libgio|libgmodule|libgtk|libgdk|libpango|libcairo|libatk|libX|libxcb|libxkb|libwayland|libEGL|libGL|libGLX|libGLdispatch|libOpenGL|libvulkan|libdrm|libgbm|libdbus|libsystemd|libudev|libasound|libpulse|libfontconfig|libfreetype|libharfbuzz|libfribidi|libexpat|libffi|libpcre|libmount|libblkid|libselinux|libcap\.so|libgcrypt|libgpg-error|liblzma|liblz4|libzstd\.so|libbz2|libpng|libjpeg|libbrotli|libssl|libcrypto|libnghttp|libcurl|libidn|libunistring|libpsl|libkrb5|libgssapi|libcom_err|libk5crypto|libkrb5support|libkeyutils|libuuid\.so|libsecret|libjson)'

for _pass in 1 2 3; do
  # Both our lib dir AND the Flutter bundle's plugin .so files: plugins can
  # link non-baseline libs of their own (tray_manager -> ayatana-appindicator,
  # hotkey_manager -> keybinder-3.0 — neither ships on a stock GNOME host),
  # and whatever they need must ride along just like libmpv's closure.
  for so in "$APPDIR"/usr/lib/*.so* "$APPDIR"/usr/bundle/lib/*.so*; do
    ldd "$so" 2>/dev/null | awk '/=>/ {print $1, $3}' | while read -r name path; do
      [ -f "$path" ] || continue
      base="$(basename "$name")"
      echo "$base" | grep -qE "$BASELINE_RE" && continue
      [ -f "$APPDIR/usr/lib/$base" ] || cp -L "$path" "$APPDIR/usr/lib/"
    done
  done
done

# 3. AppRun: exec the binary from its bundle dir so relative data/ lookups
#    work; put our lib dir on LD_LIBRARY_PATH for the dlopen of libmpv.
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="$HERE/usr/lib:$HERE/usr/bundle/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$HERE/usr/bundle/tangent" "$@"
EOF
chmod +x "$APPDIR/AppRun"

# 4. Desktop entry + icon.
cat > "$APPDIR/tangent.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Tangent
Comment=Self-hosted voice brain-dump for ADHD brains
Exec=tangent
Icon=tangent
Terminal=false
Categories=AudioVideo;Utility;
EOF
cp "$HERE/tangent.png" "$APPDIR/tangent.png"

# 5. Build.
mkdir -p "$OUT_DIR"
ARCH=x86_64 "$APPIMAGETOOL" -n "$APPDIR" "$OUT_DIR/Tangent-x86_64.AppImage"
echo "built: $OUT_DIR/Tangent-x86_64.AppImage"
