// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../models/notebook.dart';
import '../theme/tangent_tokens.dart';

/// Shows a tool's ink palette anchored near [globalPosition].
///
/// Returns the chosen colour, or null if the sheet was dismissed without a
/// choice — callers must treat null as "leave the current colour alone",
/// never as a reset.
Future<InkColor?> showInkPalette({
  required BuildContext context,
  required InkTool tool,
  required InkColor selected,
  required Offset globalPosition,
}) {
  final Size screen = MediaQuery.sizeOf(context);
  return showMenu<InkColor>(
    context: context,
    position: RelativeRect.fromLTRB(
      globalPosition.dx,
      globalPosition.dy,
      screen.width - globalPosition.dx,
      screen.height - globalPosition.dy,
    ),
    color: TangentColors.panel,
    items: <PopupMenuEntry<InkColor>>[
      PopupMenuItem<InkColor>(
        enabled: false,
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final InkColor colour in InkColor.paletteFor(tool))
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: InkSwatch(
                  colour: colour,
                  selected: colour == selected,
                  onTap: () => Navigator.of(context).pop(colour),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

/// One circular swatch. A highlighter's translucency is shown against the
/// page colour, so the swatch previews the mark rather than the raw value.
class InkSwatch extends StatelessWidget {
  const InkSwatch({
    super.key,
    required this.colour,
    required this.selected,
    required this.onTap,
  });

  final InkColor colour;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        label: colour.wireValue,
        child: GestureDetector(
          key: ValueKey<String>('notebook-ink-swatch-${colour.wireValue}'),
          onTap: onTap,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: TangentColors.sunken,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? TangentColors.signal : TangentColors.edge,
                width: selected ? 2 : 1,
              ),
            ),
            child: Center(
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: Color(colour.argb),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      );
}
