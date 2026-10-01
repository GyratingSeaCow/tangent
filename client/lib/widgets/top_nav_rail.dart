// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../theme/tangent_tokens.dart';

/// The six top-level destinations of the Instrument Console.
///
/// Pushed screens highlight the root they belong to: a recording's detail
/// screen is still "Recordings", the notebook editor is still "Notebooks",
/// the morning review is still "Capture".
enum TangentRoot { capture, recordings, notebooks, todo, ask, settings }

/// Stable per-destination keys so tests and tooling can address a rail
/// button without relying on icon uniqueness across the screen.
Key railKey(TangentRoot root) => Key('rail-${root.name}');

/// Instrument Console v2 top navigation rail.
///
/// A right-aligned row of 48dp icon buttons above the app bar, present on
/// every top-level screen. The active destination renders in the signal
/// colour on a tinted pill; taps on it are no-ops. Icons intentionally match
/// the pre-rail app-bar glyphs so the destinations stay recognizable.
class TopNavRail extends StatelessWidget {
  const TopNavRail({
    super.key,
    required this.active,
    required this.onSelect,
  });

  /// Which destination the current screen belongs to.
  final TangentRoot active;

  /// Called with the tapped destination. Never called for [active].
  final ValueChanged<TangentRoot> onSelect;

  static const double height = 50;

  /// Tint behind the active destination's icon — one step above sunken,
  /// below panel, matching the mockup's quiet pill.
  static const Color activeTint = Color(0xFF1D282B);

  static const List<(TangentRoot, IconData, String)> destinations = [
    (TangentRoot.capture, Icons.home, 'Capture'),
    (TangentRoot.recordings, Icons.list, 'Recordings'),
    (TangentRoot.notebooks, Icons.menu_book, 'Notebooks'),
    (TangentRoot.todo, Icons.check_box, 'To Do'),
    (TangentRoot.ask, Icons.question_answer, 'Ask'),
    (TangentRoot.settings, Icons.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      color: TangentColors.sunken,
      padding: const EdgeInsets.symmetric(horizontal: TangentSpacing.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          for (final (root, icon, label) in destinations)
            _RailButton(
              root: root,
              icon: icon,
              label: label,
              isActive: root == active,
              onSelect: onSelect,
            ),
        ],
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.root,
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onSelect,
  });

  final TangentRoot root;
  final IconData icon;
  final String label;
  final bool isActive;
  final ValueChanged<TangentRoot> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: isActive
          ? BoxDecoration(
              color: TopNavRail.activeTint,
              borderRadius: BorderRadius.circular(TangentShapes.panelRadius),
            )
          : null,
      child: IconButton(
        key: railKey(root),
        icon: Icon(icon),
        tooltip: label,
        color: isActive ? TangentColors.signal : TangentColors.textDim,
        onPressed: isActive ? null : () => onSelect(root),
        // A disabled IconButton would grey out; the active destination is
        // lit, not disabled, so pin its colour through disabledColor too.
        disabledColor: isActive ? TangentColors.signal : null,
      ),
    );
  }
}
