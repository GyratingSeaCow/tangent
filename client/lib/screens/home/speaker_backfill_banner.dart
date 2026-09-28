// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Leftovers sweep L5: the v20 speaker-name back-fill refuses ambiguous
// pairings rather than merge two speakers, and used to do so silently.
// The migration now records those dump ids in the `settings` table
// (`speaker_backfill_skipped`, a JSON list, local-only); Home shows them
// ONCE as a dismissible banner above the record area. Tapping the text
// opens Recordings filtered to exactly those ids; dismissing deletes the
// row, so the banner never returns. No skips → nothing rendered.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../dump/dumps_list_screen.dart';
import 'home_screen.dart' show localDbProvider;

/// The refused dump ids, read once per Home lifetime and re-read after a
/// dismiss ([SpeakerBackfillBanner] invalidates it).
final FutureProvider<List<String>> speakerBackfillSkippedProvider =
    FutureProvider<List<String>>(
  (Ref ref) => ref.watch(localDbProvider).speakerBackfillSkippedIds(),
);

/// The banner copy for [count] refused recordings (spec L5).
String speakerBackfillBannerText(int count) => count == 1
    ? '1 recording kept its old speaker headings — open it to name '
        'speakers again'
    : '$count recordings kept their old speaker headings — open one to '
        'name speakers again';

class SpeakerBackfillBanner extends ConsumerWidget {
  const SpeakerBackfillBanner({super.key});

  static const Key bannerKey = Key('speaker-backfill-banner');
  static const Key dismissKey = Key('speaker-backfill-banner-dismiss');

  Future<void> _dismiss(WidgetRef ref) async {
    await ref.read(localDbProvider).clearSpeakerBackfillSkipped();
    ref.invalidate(speakerBackfillSkippedProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<String> ids =
        ref.watch(speakerBackfillSkippedProvider).valueOrNull ??
            const <String>[];
    if (ids.isEmpty) return const SizedBox.shrink();
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Material(
        key: bannerKey,
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
        child: Row(
          children: <Widget>[
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => DumpsListScreen(filterIds: ids.toSet()),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                  child: Text(
                    speakerBackfillBannerText(ids.length),
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: scheme.onSecondaryContainer),
                  ),
                ),
              ),
            ),
            IconButton(
              key: dismissKey,
              tooltip: 'Dismiss',
              icon: Icon(Icons.close, color: scheme.onSecondaryContainer),
              onPressed: () => _dismiss(ref),
            ),
          ],
        ),
      ),
    );
  }
}
