// SPDX-License-Identifier: AGPL-3.0-or-later

/// The one file-name sanitiser every export path uses.
///
/// Strips the characters no filesystem (or SAF provider) accepts in a file
/// name, and falls back to [fallback] when the title is blank so an untitled
/// item still gets a usable file. Introduced for the notebook PDF export;
/// the Markdown export reuses it so both paths name files identically.
String safeExportStem(String title, {required String fallback}) {
  final String trimmed = title.trim();
  if (trimmed.isEmpty) return fallback;
  return trimmed.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
}
