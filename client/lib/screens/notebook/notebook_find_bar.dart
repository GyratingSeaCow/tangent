// SPDX-License-Identifier: AGPL-3.0-or-later
/// The notebook's Ctrl+F bar: query field, "n/m" position, prev/next, close.
///
/// Pure presentation, like [PenSizeControl]: the EDITOR owns the match list
/// and the current index, because it also owns the canvas the highlights
/// paint on and the scroll controller the current match is brought into view
/// with. This widget only renders that state and reports intent upward.
library;

import 'package:flutter/material.dart';

class NotebookFindBar extends StatelessWidget {
  const NotebookFindBar({
    super.key,
    required this.controller,
    required this.matchCount,
    required this.currentIndex,
    required this.onQueryChanged,
    required this.onPrev,
    required this.onNext,
    required this.onClose,
  });

  /// The query text, owned by the editor so a deep-linked query (home-screen
  /// search) arrives already populated.
  final TextEditingController controller;

  /// Total matches for the current query.
  final int matchCount;

  /// Zero-based index of the current match; ignored when [matchCount] is 0.
  final int currentIndex;

  final ValueChanged<String> onQueryChanged;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool hasMatches = matchCount > 0;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                key: const ValueKey<String>('notebook-find-field'),
                controller: controller,
                autofocus: true,
                onChanged: onQueryChanged,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'Find in notebook…',
                  border: InputBorder.none,
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 18),
                ),
              ),
            ),
            // "n/m" — 0/0 while the query matches nothing, so an empty
            // result is stated rather than shown as a blank.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                key: const ValueKey<String>('notebook-find-position'),
                hasMatches ? '${currentIndex + 1}/$matchCount' : '0/0',
                style: theme.textTheme.bodySmall,
              ),
            ),
            IconButton(
              key: const ValueKey<String>('notebook-find-prev'),
              icon: const Icon(Icons.keyboard_arrow_up),
              tooltip: 'Previous match',
              visualDensity: VisualDensity.compact,
              // Dead without matches: walking an empty list means nothing,
              // and a disabled arrow says so honestly.
              onPressed: hasMatches ? onPrev : null,
            ),
            IconButton(
              key: const ValueKey<String>('notebook-find-next'),
              icon: const Icon(Icons.keyboard_arrow_down),
              tooltip: 'Next match',
              visualDensity: VisualDensity.compact,
              onPressed: hasMatches ? onNext : null,
            ),
            IconButton(
              key: const ValueKey<String>('notebook-find-close'),
              icon: const Icon(Icons.close),
              tooltip: 'Close find',
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}
