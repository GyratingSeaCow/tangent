// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The app's one long-press menu.
//
// Every list — notebooks, recordings, text notes — long-presses into THIS
// sheet, so the gesture means the same thing everywhere. Before it existed, a
// long-press on a notebook deleted it outright while the same gesture on a
// recording started multi-select: two contracts for one gesture, one of them
// destructive and unguarded.
//
// The sheet decides presentation (order, wording, destructive styling); each
// screen decides which actions apply and what they do.
import 'package:flutter/material.dart';

import '../theme/tangent_tokens.dart';

/// An action a list item can offer on long-press.
///
/// Screens pass the subset that applies to them. The sheet owns the label and
/// icon for each, so "Rename" reads identically in every list.
enum ItemAction {
  open,
  rename,
  move,
  duplicate,
  share,
  select,
  delete,
}

/// Actions that destroy something. Sorted last, painted in the danger colour.
const Set<ItemAction> _destructive = <ItemAction>{ItemAction.delete};

/// The canonical order. A screen may pass actions in any order; the sheet
/// renders them in this one, so the menu never reshuffles between screens and
/// muscle memory keeps working.
const List<ItemAction> _canonicalOrder = <ItemAction>[
  ItemAction.open,
  ItemAction.rename,
  ItemAction.move,
  ItemAction.duplicate,
  ItemAction.share,
  ItemAction.select,
  ItemAction.delete,
];

class ItemActionSheet extends StatelessWidget {
  const ItemActionSheet({
    super.key,
    required this.title,
    required this.actions,
    this.subtitle,
    this.disabledActions = const <ItemAction, String>{},
  });

  final String title;
  final String? subtitle;
  final List<ItemAction> actions;

  /// Actions that are shown but not selectable, mapped to the reason why.
  ///
  /// Deliberately not "omit the action": a recording that is syncing or
  /// publishing cannot be deleted yet, and a Delete row that disappears reads
  /// as a bug. A greyed row that says "Syncing" explains the app to the user.
  final Map<ItemAction, String> disabledActions;

  /// Stable key per action, so tests and later restyling both survive.
  static Key keyFor(ItemAction action) => ValueKey<String>('item-action-${action.name}');

  static String labelFor(ItemAction action) {
    switch (action) {
      case ItemAction.open:
        return 'Open';
      case ItemAction.rename:
        return 'Rename';
      case ItemAction.move:
        return 'Move to folder';
      case ItemAction.duplicate:
        return 'Duplicate';
      case ItemAction.share:
        return 'Share';
      case ItemAction.select:
        return 'Select';
      case ItemAction.delete:
        return 'Delete';
    }
  }

  static IconData iconFor(ItemAction action) {
    switch (action) {
      case ItemAction.open:
        return Icons.open_in_new;
      case ItemAction.rename:
        return Icons.drive_file_rename_outline;
      case ItemAction.move:
        return Icons.drive_file_move_outline;
      case ItemAction.duplicate:
        return Icons.copy_all_outlined;
      case ItemAction.share:
        return Icons.ios_share;
      case ItemAction.select:
        return Icons.check_circle_outline;
      case ItemAction.delete:
        return Icons.delete_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color danger = TangentColors.record;

    final List<ItemAction> ordered = <ItemAction>[
      for (final ItemAction candidate in _canonicalOrder)
        if (actions.contains(candidate)) candidate,
    ];

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          // A long action list on a short screen (or with a keyboard up) must
          // scroll rather than overflow: Flexible keeps the sheet at its
          // natural height when it fits, and scrolls when it does not.
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: <Widget>[
                for (final ItemAction action in ordered)
                  Builder(
                    builder: (BuildContext context) {
                      final String? blocked = disabledActions[action];
                      final bool isDisabled = blocked != null;
                      final Color? tint = isDisabled
                          ? theme.disabledColor
                          : (_destructive.contains(action) ? danger : null);
                      return ListTile(
                        key: keyFor(action),
                        enabled: !isDisabled,
                        leading: Icon(iconFor(action), color: tint),
                        title: Text(
                          labelFor(action),
                          style: tint == null ? null : TextStyle(color: tint),
                        ),
                        subtitle: blocked == null ? null : Text(blocked),
                        onTap: isDisabled
                            ? null
                            : () => Navigator.of(context).pop(action),
                      );
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Shows the shared long-press menu and resolves to the chosen action, or null
/// when the user dismissed it.
Future<ItemAction?> showItemActionSheet(
  BuildContext context, {
  required String title,
  required List<ItemAction> actions,
  String? subtitle,
  Map<ItemAction, String> disabledActions = const <ItemAction, String>{},
}) {
  return showModalBottomSheet<ItemAction>(
    context: context,
    showDragHandle: true,
    builder: (BuildContext sheetContext) => ItemActionSheet(
      title: title,
      subtitle: subtitle,
      actions: actions,
      disabledActions: disabledActions,
    ),
  );
}
