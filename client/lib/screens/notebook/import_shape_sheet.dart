// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The one "how should this recording land on the page?" sheet, shared by the
// editor's Import entries and the recordings' "Send to notebook…" action
// (transcript-to-notebook spec §A) so both flows ask the identical question
// and one widget test covers it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/notebook_import.dart';
import '../settings/settings_screen.dart' show settingsStoreProvider;

/// What the user picked on the shape sheet.
class ImportShapeChoice {
  const ImportShapeChoice({
    required this.shape,
    required this.includeAudioCard,
  });

  final ImportShape shape;

  /// Whether a text-ish shape also drops an Audio bubble beside the text so
  /// the `[mm:ss]` stamps have a player to seek in place (spec §C). Always
  /// true for [ImportShape.audio] — the card IS the import.
  final bool includeAudioCard;
}

/// Asks whether the import lands as audio bubbles or transcript text — plus,
/// when [offerSummary], the summary alone or summary-and-transcript. The
/// "Include audio bubble" switch starts at [initialIncludeAudioCard] and
/// belongs to the text shapes only: it sits under them, after a divider, and
/// the Audio bubble row above the divider is unaffected by it. Dismissing
/// returns null and nothing inserts.
Future<ImportShapeChoice?> askImportShape(
  BuildContext context, {
  required bool offerSummary,
  required bool initialIncludeAudioCard,
}) =>
    showModalBottomSheet<ImportShapeChoice>(
      context: context,
      builder: (BuildContext sheetContext) => _ImportShapeSheet(
        offerSummary: offerSummary,
        initialIncludeAudioCard: initialIncludeAudioCard,
      ),
    );

/// [askImportShape] with the switch seeded from — and written back to — the
/// device's SettingsStore (`notebook-import-audio-card`, default on), so
/// the user's last answer sticks across imports. Every production call site
/// goes through here; the bare [askImportShape] exists for tests.
Future<ImportShapeChoice?> askImportShapeRemembered(
  BuildContext context,
  WidgetRef ref, {
  required bool offerSummary,
}) async {
  final bool initial = ref.read(settingsStoreProvider).notebookImportAudioCard;
  final ImportShapeChoice? choice = await askImportShape(
    context,
    offerSummary: offerSummary,
    initialIncludeAudioCard: initial,
  );
  if (choice != null &&
      choice.shape != ImportShape.audio &&
      choice.includeAudioCard != initial) {
    await ref
        .read(settingsStoreProvider)
        .setNotebookImportAudioCard(choice.includeAudioCard);
  }
  return choice;
}

class _ImportShapeSheet extends StatefulWidget {
  const _ImportShapeSheet({
    required this.offerSummary,
    required this.initialIncludeAudioCard,
  });

  final bool offerSummary;
  final bool initialIncludeAudioCard;

  @override
  State<_ImportShapeSheet> createState() => _ImportShapeSheetState();
}

class _ImportShapeSheetState extends State<_ImportShapeSheet> {
  late bool _includeAudioCard = widget.initialIncludeAudioCard;

  void _pick(ImportShape shape) => Navigator.of(context).pop(
        ImportShapeChoice(
          shape: shape,
          includeAudioCard:
              shape == ImportShape.audio ? true : _includeAudioCard,
        ),
      );

  @override
  // Scrollable: with the summary shapes and the switch the sheet is five
  // rows, which overflows a short landscape viewport otherwise.
  Widget build(BuildContext context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                key: const ValueKey<String>('import-as-card'),
                leading: const Icon(Icons.graphic_eq),
                title: const Text('Audio bubble'),
                subtitle: const Text('A playable card you can drag around'),
                onTap: () => _pick(ImportShape.audio),
              ),
              const Divider(height: 1),
              ListTile(
                key: const ValueKey<String>('import-as-text'),
                leading: const Icon(Icons.notes),
                title: const Text('Text'),
                subtitle: const Text('The transcript, in an editable text box'),
                onTap: () => _pick(ImportShape.text),
              ),
              if (widget.offerSummary) ...<Widget>[
                ListTile(
                  key: const ValueKey<String>('import-as-summary'),
                  leading: const Icon(Icons.auto_awesome_outlined),
                  title: const Text('Summary'),
                  subtitle: const Text(
                    'Key points and action items, in an editable text box',
                  ),
                  onTap: () => _pick(ImportShape.summary),
                ),
                ListTile(
                  key: const ValueKey<String>('import-as-both'),
                  leading: const Icon(Icons.library_books),
                  title: const Text('Transcript + summary'),
                  subtitle: const Text(
                    'Both, as two text boxes — summary first',
                  ),
                  onTap: () => _pick(ImportShape.both),
                ),
              ],
              // Applies to the text shapes above it: the card gives the
              // [mm:ss] stamps a player to seek in place. The Audio bubble row
              // IS the card, so it sits on the other side of the divider.
              SwitchListTile(
                key: const ValueKey<String>('import-include-audio'),
                secondary: const Icon(Icons.graphic_eq),
                title: const Text('Include audio bubble'),
                subtitle: const Text(
                  'Also add a playable card next to the text shapes',
                ),
                value: _includeAudioCard,
                onChanged: (bool value) =>
                    setState(() => _includeAudioCard = value),
              ),
            ],
          ),
        ),
      );
}
