// SPDX-License-Identifier: AGPL-3.0-or-later
/// The shared "summarize with a template" flow behind both entry points —
/// the dump detail's Summarize / Summarize again button and the recordings
/// list's ⋮ Regenerate summary action.
///
/// Picker → POST /v1/dumps/{id}/summarize {"template": id} → snackbar. The
/// preset list is fetched from the server every time (never hardcoded: a
/// server that adds a preset shows it on every device without a client
/// release), 'Custom' appears only while the server says the custom slot is
/// configured, and the dump's current EFFECTIVE template is marked.
///
/// Preserve-until-success: nothing here clears or polls the existing
/// summary. A 202 only means "queued"; the new summary replaces the old one
/// when it lands via normal dump sync, exactly like re-transcription.
library;

import 'package:flutter/material.dart';

import '../../data/local_db.dart';
import '../../services/summaries_client.dart';

/// The template the server will use for [dumpTemplate]/[mode] when no
/// explicit choice is posted: the dump's persisted choice, else the mode
/// default. Mirrors the server's own rule so the picker marks the row the
/// server would actually apply.
///
/// Mode defaults: meeting → 'meeting'; brain_dump and text_note → the
/// prose-oriented 'brain_dump' (a typed note has no attendees or action
/// framing either). Unknown modes fall back to 'brain_dump' as well.
String effectiveTemplateId(String? dumpTemplate, String mode) {
  final String? chosen = dumpTemplate?.trim();
  if (chosen != null && chosen.isNotEmpty) return chosen;
  return switch (mode) {
    'meeting' => 'meeting',
    _ => 'brain_dump',
  };
}

/// Modal bottom sheet listing the server's summary templates. Pops the
/// chosen template id, or null when dismissed.
class SummaryTemplateSheet extends StatelessWidget {
  const SummaryTemplateSheet({
    super.key,
    required this.templates,
    required this.currentId,
  });

  /// Rows in server order, already filtered for the custom slot.
  final List<SummaryTemplate> templates;

  /// The dump's current effective template — marked, never preselected as
  /// a result: the user still has to tap to summarize.
  final String currentId;

  /// Shows the picker. The 'custom' row is dropped unless
  /// [customConfigured] — an empty slot is not something to offer.
  static Future<String?> show(
    BuildContext context, {
    required SummaryTemplates catalogue,
    required String currentId,
  }) {
    final List<SummaryTemplate> rows = <SummaryTemplate>[
      for (final SummaryTemplate t in catalogue.templates)
        if (t.id != 'custom' || catalogue.customConfigured) t,
    ];
    return showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext sheetContext) => SummaryTemplateSheet(
        templates: rows,
        currentId: currentId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SafeArea(
      child: Column(
        key: const ValueKey<String>('summary-template-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Summary template', style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Choose how your server should write this summary. The '
              'current summary stays until the new one arrives.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (templates.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('No templates available')),
            ),
          // Flexible + shrinkWrap: the sheet takes only what the rows need,
          // yet a short phone (or a server with many presets) scrolls
          // instead of overflowing the sheet's height cap.
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 8),
              children: <Widget>[
                for (final SummaryTemplate t in templates)
                  ListTile(
                    key: ValueKey<String>('summary-template-${t.id}'),
                    title: Text(t.displayName),
                    selected: t.id == currentId,
                    trailing: t.id == currentId
                        ? Icon(
                            Icons.check,
                            key: ValueKey<String>(
                              'summary-template-current-${t.id}',
                            ),
                            semanticLabel: 'Current template',
                          )
                        : null,
                    onTap: () => Navigator.of(context).pop(t.id),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Runs the whole flow for [dump]: fetch templates, pick, POST, report.
///
/// [client] is awaited lazily so a provider failure surfaces as the same
/// "could not" snackbar as any other transport error. Every user-visible
/// outcome is a snackbar on [context]'s ScaffoldMessenger; the two typed
/// 409s route differently (a missing capability sends the user to Settings,
/// a transcript-less dump is explained on the spot) and a typed 422 shows
/// the server's own wording (which case: unknown id or custom not set up).
Future<void> runSummarizeFlow(
  BuildContext context, {
  required Future<SummariesClient> client,
  required DumpRow dump,
}) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final SummariesClient summaries;
  final SummaryTemplates catalogue;
  try {
    summaries = await client;
    catalogue = await summaries.listTemplates();
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Could not load summary templates: $e')),
    );
    return;
  }
  if (!context.mounted) return;
  final String? picked = await SummaryTemplateSheet.show(
    context,
    catalogue: catalogue,
    currentId: effectiveTemplateId(dump.summaryTemplate, dump.mode),
  );
  if (picked == null) return;
  try {
    await summaries.summarizeDump(dump.id, template: picked);
    messenger.showSnackBar(
      const SnackBar(content: Text('Summary queued')),
    );
  } on SummarizeConflictException catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          switch (e.reason) {
            SummarizeConflictReason.notInstalled =>
              'Install AI summaries in Settings first',
            SummarizeConflictReason.noTranscript =>
              'This recording has no transcript yet',
          },
        ),
      ),
    );
  } on SummaryTemplateException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Could not queue summary: $e')),
    );
  }
}
