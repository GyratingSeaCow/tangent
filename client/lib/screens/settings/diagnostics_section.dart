// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../services/debug_log_export.dart';
import '../../theme/tangent_tokens.dart';
import '../home/home_screen.dart';

/// Where a diagnostics snapshot goes so it can be pulled off a release
/// build. On Android that is the app's external files dir —
/// `Android/data/<package>/files/` — readable by `adb pull` and any file
/// manager without root or a debuggable build. Elsewhere the support dir
/// is fine: a desktop user can already open it.
Future<Directory> diagnosticsDirectory() async {
  if (Platform.isAndroid) {
    final external = await getExternalStorageDirectory();
    if (external != null) return external;
  }
  return getApplicationSupportDirectory();
}

class DiagnosticsSection extends ConsumerStatefulWidget {
  const DiagnosticsSection({super.key});

  @override
  ConsumerState<DiagnosticsSection> createState() => _DiagnosticsSectionState();
}

class _DiagnosticsSectionState extends ConsumerState<DiagnosticsSection> {
  bool _running = false;
  bool _exportingLogs = false;
  String? _lastPath;

  Future<void> _exportDebugLogs() async {
    setState(() => _exportingLogs = true);
    try {
      final DebugLogExportResult result = await ref
          .read(debugLogExporterProvider)
          .export();
      if (!mounted) return;
      final String message = switch (result.route) {
        DebugLogExportRoute.attachedEmail =>
          'Opening an email with debug logs attached…',
        DebugLogExportRoute.mailto =>
          'No app accepted the attachment; opening an email with truncated logs…',
        DebugLogExportRoute.sharedFile =>
          Platform.isLinux || Platform.isWindows
              ? 'Saved debug logs to Tangent/Exports and opened the file.'
              : 'Opening the file share sheet…',
        DebugLogExportRoute.unavailable =>
          'No email or share app is available. Log saved to ${result.filePath}',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Debug log export failed: $error')),
      );
    } finally {
      if (mounted) setState(() => _exportingLogs = false);
    }
  }

  Future<void> _export() async {
    setState(() => _running = true);
    try {
      final dir = await diagnosticsDirectory();
      final target = File(p.join(dir.path, 'tangent-diagnostics.sqlite'));
      final written =
          await ref.read(localDbProvider).writeDiagnosticSnapshot(target);
      if (!mounted) return;
      setState(() => _lastPath = written.path);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Database copy written to ${written.path}')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Database copy failed: $error')),
      );
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          key: const ValueKey<String>('export-debug-logs'),
          leading: _exportingLogs
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.email_outlined),
          title: const Text('Export debug logs'),
          subtitle: const Text(
            'Emails recent runtime errors and stack traces to Tangent support. '
            'Errors and stacks are sanitized before storage; SQL details, '
            'credentials, and transcript or note-content fields are removed.',
          ),
          onTap: _exportingLogs ? null : _exportDebugLogs,
        ),
        const Divider(),
        ListTile(
          leading: _running
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.bug_report_outlined),
          title: const Text('Export database copy'),
          subtitle: const Text(
            'Writes a snapshot of this device\'s local database (recording '
            'metadata, transcripts, sync state — no audio) for '
            'troubleshooting. Nothing is uploaded.',
          ),
          onTap: _running ? null : _export,
        ),
        if (_lastPath != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    _lastPath!,
                    style: const TextStyle(
                      color: TangentColors.textDim,
                      fontSize: 12,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy path',
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: _lastPath!)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
