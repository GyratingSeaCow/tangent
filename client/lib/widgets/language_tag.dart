// SPDX-License-Identifier: AGPL-3.0-or-later
/// The per-recording language tag (v1.19.0 Part A, T2=y): 'ES' when the
/// transcript is in the original non-English language, 'ES → EN' once it has
/// been translated. Renders NOTHING for English or unknown-language rows so
/// the common case carries no noise.
library;

import 'package:flutter/material.dart';

import '../data/local_db.dart';
import '../services/language_display.dart';

class LanguageTag extends StatelessWidget {
  const LanguageTag(this.row, {super.key});

  final DumpRow row;

  /// The chip text, or null when no tag should show.
  static String? labelFor(DumpRow row) {
    final String? code = row.language;
    if (!isForeignLanguage(code)) return null;
    final String upper = code!.trim().toUpperCase();
    return (row.translated ?? false) ? '$upper → EN' : upper;
  }

  @override
  Widget build(BuildContext context) {
    final String? label = labelFor(row);
    if (label == null) return const SizedBox.shrink();
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      key: ValueKey<String>('language-tag-${row.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        border: Border.all(color: colors.secondary),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.translate, size: 14, color: colors.onSecondaryContainer),
          const SizedBox(width: 5),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: colors.onSecondaryContainer,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}
