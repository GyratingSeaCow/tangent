// SPDX-License-Identifier: AGPL-3.0-or-later
//
// How tags look on a list row, and the one tag filter both lists share.
//
// Display contract: tags NEVER add a line to a row. They ride the title line
// as one ellipsized label capped at a fraction of the row width, so a
// notebook with twelve tags is exactly as tall as one with none.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/tag_repository.dart';

/// `#work #ideas …` on a single line.
class TagLabel extends StatelessWidget {
  const TagLabel({super.key, required this.names});

  final List<String> names;

  static String textFor(List<String> names) =>
      names.map((String n) => '#$n').join(' ');

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Text(
      textFor(names),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.primary,
      ),
    );
  }
}

/// A row title with its tags trailing on the SAME line.
///
/// The title takes what it needs first; tags get at most [maxTagFraction] of
/// the width and ellipsize inside it. With no tags this is exactly the old
/// `Row(leading…, Expanded(title))`.
class TaggedTitleRow extends StatelessWidget {
  const TaggedTitleRow({
    super.key,
    required this.title,
    required this.tagNames,
    this.leading = const <Widget>[],
    this.tagKey,
    this.maxTagFraction = 0.42,
  });

  final Widget title;
  final List<String> tagNames;
  final List<Widget> leading;
  final Key? tagKey;
  final double maxTagFraction;

  @override
  Widget build(BuildContext context) {
    if (tagNames.isEmpty) {
      return Row(
        children: <Widget>[
          ...leading,
          Expanded(child: title),
        ],
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double cap = constraints.maxWidth.isFinite
            ? constraints.maxWidth * maxTagFraction
            : 160;
        return Row(
          children: <Widget>[
            ...leading,
            Expanded(child: title),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: cap),
              child: TagLabel(key: tagKey, names: tagNames),
            ),
          ],
        );
      },
    );
  }
}

/// The tag filter, identical on the notebook and recording lists.
///
/// Hidden while the vocabulary is empty: a filter with nothing to choose is
/// noise. A selected tag that has since been deleted reads (and filters) as
/// "All" — see [effectiveTagFilter].
class TagFilterBar extends ConsumerWidget {
  const TagFilterBar({super.key, required this.targetType});

  final String targetType;

  static const Key menuKey = ValueKey<String>('tag-filter-menu');
  static const Key allKey = ValueKey<String>('tag-filter-all');
  static Key keyFor(String tagId) => ValueKey<String>('tag-filter-$tagId');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<TagSummary> tags =
        ref.watch(tagsProvider).valueOrNull ?? const <TagSummary>[];
    if (tags.isEmpty) return const SizedBox.shrink();
    final String? selected = effectiveTagFilter(
      ref.watch(tagFilterProvider(targetType)),
      tags,
    );
    String label = 'All';
    for (final TagSummary tag in tags) {
      if (tag.id == selected) label = '#${tag.name}';
    }
    void choose(String? id) =>
        ref.read(tagFilterProvider(targetType).notifier).state = id;
    Widget mark(bool on) => on
        ? const Icon(Icons.check, size: 18)
        : const SizedBox.square(dimension: 18);
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Row(
        children: <Widget>[
          Expanded(
            child: MenuAnchor(
              menuChildren: <Widget>[
                MenuItemButton(
                  key: allKey,
                  leadingIcon: mark(selected == null),
                  onPressed: () => choose(null),
                  child: const Text('All'),
                ),
                for (final TagSummary tag in tags)
                  MenuItemButton(
                    key: keyFor(tag.id),
                    leadingIcon: mark(tag.id == selected),
                    onPressed: () => choose(tag.id),
                    child: Text('#${tag.name}'),
                  ),
              ],
              builder:
                  (
                    BuildContext context,
                    MenuController controller,
                    Widget? _,
                  ) => OutlinedButton.icon(
                    key: menuKey,
                    onPressed: () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
                    style: OutlinedButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    icon: const Icon(Icons.arrow_drop_down),
                    iconAlignment: IconAlignment.end,
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const Icon(Icons.sell_outlined, size: 16),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'Tag · $label',
                            style: theme.textTheme.labelLarge,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
