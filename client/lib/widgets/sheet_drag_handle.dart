// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The one drag handle every Tangent bottom sheet wears (Instrument Console
// v2). Material's built-in `showDragHandle` draws its own bar in
// onSurfaceVariant with its own paddings; this widget is the house version —
// a 40x3 rounded bar in dimmed textDim — placed INSIDE each sheet body so
// every sheet top reads identically whatever presents it.
import 'package:flutter/material.dart';

import '../theme/tangent_tokens.dart';

/// A 40x3 rounded grab bar centred at the top of a bottom sheet.
///
/// Purely presentational: the sheet's drag-to-dismiss gesture belongs to the
/// modal route, not to this widget.
class SheetDragHandle extends StatelessWidget {
  const SheetDragHandle({super.key});

  /// The whole handle strip, for existence checks.
  static const Key handleKey = ValueKey<String>('sheet-drag-handle');

  /// The visible bar itself, for size assertions.
  static const Key barKey = ValueKey<String>('sheet-drag-handle-bar');

  @override
  Widget build(BuildContext context) => Center(
        key: handleKey,
        child: Padding(
          padding: const EdgeInsets.only(
            top: TangentSpacing.md,
            bottom: TangentSpacing.xs,
          ),
          child: Container(
            key: barKey,
            width: 40,
            height: 3,
            decoration: BoxDecoration(
              color: TangentColors.textDim.withValues(alpha: 0.6),
              // A 3dp grab bar: the tag radius already rounds it fully.
              borderRadius: BorderRadius.circular(TangentShapes.radiusTag),
            ),
          ),
        ),
      );
}
