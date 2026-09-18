// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/dump.dart';
import '../models/dump_mode.dart';

/// Material icon representing a dump's capture mode.
IconData dumpModeIcon(DumpMode mode) => switch (mode) {
      DumpMode.brainDump => Icons.mic,
      DumpMode.meeting => Icons.groups,
      DumpMode.textNote => Icons.notes,
    };

/// Human duration for a dump, e.g. `95` -> `1m 35s`.
String formatDumpDuration(int seconds) {
  final safe = seconds < 0 ? 0 : seconds;
  final mins = safe ~/ 60;
  final secs = safe % 60;
  return mins > 0 ? '${mins}m ${secs}s' : '${secs}s';
}

/// A compact, draggable "floating box" representing a dump embedded in a
/// notebook page.
///
/// MUST be placed directly inside a [Stack]: the card renders as a
/// [Positioned] at [position], which is logical pixels from the stack's
/// top-left corner (matching the `x`/`y` of a `dumpCard` block).
///
/// A null [dump] means the referenced recording no longer exists. The card
/// then renders a visibly disabled "Recording unavailable" placeholder — it is
/// never silently dropped and never throws. The placeholder stays draggable
/// and removable so the user can tidy it up.
class NotebookDumpCard extends StatefulWidget {
  const NotebookDumpCard({
    super.key,
    required this.dump,
    required this.position,
    required this.onPositionChanged,
    this.onTap,
    this.onRemove,
    this.onDragActive,
  });

  /// The embedded dump, or null when the referenced dump no longer exists.
  final Dump? dump;

  /// Logical pixels from the parent [Stack]'s top-left corner.
  final Offset position;

  /// Reports the new [position] during and at the end of a drag. The parent
  /// owns the truth: whatever it stores (clamped, snapped, or verbatim) is
  /// what the card renders once the drag finishes.
  final ValueChanged<Offset> onPositionChanged;

  /// Opens the dump. Ignored for the unavailable placeholder.
  final VoidCallback? onTap;

  /// Removes the card from the notebook. Omit to hide the affordance.
  final VoidCallback? onRemove;

  /// True while this card is being dragged.
  ///
  /// The pannable canvas uses this to hold still: its recognizer would
  /// otherwise win mostly-vertical drags and move the page instead of the
  /// card.
  final ValueChanged<bool>? onDragActive;

  /// Widest the floating card ever gets, so it stays a "little box".
  static const double maxCardWidth = 220;

  static const double minCardWidth = 120;
  static const double cornerRadius = 12;

  @override
  State<NotebookDumpCard> createState() => _NotebookDumpCardState();
}

/// Pan recognizer that claims the gesture immediately instead of waiting to
/// out-compete its rivals.
///
/// The notebook canvas pans with the same drags, and in a normal arena its
/// recognizer wins mostly-vertical ones — dragging the page while the user is
/// dragging a card. A card drag starts on the card itself, so there is no
/// ambiguity to resolve: resolve it as accepted at once.
class _EagerPanRecognizer extends PanGestureRecognizer {
  _EagerPanRecognizer({super.debugOwner});

  /// Where the current pointer went down, so movement can be measured from
  /// its true origin rather than per-event.
  final Map<int, Offset> _origins = <int, Offset>{};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _origins[event.pointer] = event.position;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    super.handleEvent(event);
    // Claim only once the finger has moved FARTHER THAN THE TOUCH SLOP.
    //
    // Claiming on any PointerMoveEvent at all looked right in tests and was
    // broken in the hand: tester.tap() moves exactly zero pixels, but a real
    // finger always slides a pixel or two on the way up. Those stray moves
    // were claimed as drags, so tapping a card never opened the recording and
    // the X never fired. Past the slop it is unambiguously a drag.
    if (event is PointerMoveEvent) {
      final Offset? origin = _origins[event.pointer];
      if (origin != null &&
          (event.position - origin).distance > computeHitSlop(
            event.kind,
            gestureSettings,
          )) {
        resolve(GestureDisposition.accepted);
      }
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _origins.remove(event.pointer);
    }
  }
}

class _NotebookDumpCardState extends State<NotebookDumpCard> {
  /// Where the card sat when the current drag began. Null when not dragging.
  ///
  /// The card tracks its own drag rather than reading back [widget.position]
  /// each update, so a parent that rebuilds late (or not at all) mid-gesture
  /// can never make the card lag or jitter under the finger.
  Offset? _anchor;
  Offset _dragged = Offset.zero;

  Offset get _effectivePosition =>
      _anchor == null ? widget.position : _anchor! + _dragged;

  void _onPanStart(DragStartDetails _) {
    _anchor = widget.position;
    _dragged = Offset.zero;
    // The canvas pans and zooms with the same drags a card responds to, and
    // its recognizer wins mostly-vertical ones. The page is told to hold
    // still for the duration so the card cannot be dragged out from under
    // the finger.
    widget.onDragActive?.call(true);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() => _dragged += details.delta);
    widget.onPositionChanged(_anchor! + _dragged);
  }

  void _onPanEnd() {
    widget.onDragActive?.call(false);
    if (_anchor == null) return;
    final settled = _anchor! + _dragged;
    setState(() {
      _anchor = null;
      _dragged = Offset.zero;
    });
    widget.onPositionChanged(settled);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dump = widget.dump;
    final missing = dump == null;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(NotebookDumpCard.cornerRadius),
      side: BorderSide(
        color: missing ? colors.outlineVariant : colors.outline,
      ),
    );
    final at = _effectivePosition;

    return Positioned(
      left: at.dx,
      top: at.dy,
      child: RawGestureDetector(
        // The pannable canvas competes for these same drags and its
        // recognizer wins mostly-vertical ones, which moved the page instead
        // of the card. An eager recognizer claims the gesture the moment it
        // starts on a card, so a card drag is always a card drag.
        gestures: <Type, GestureRecognizerFactory>{
          _EagerPanRecognizer:
              GestureRecognizerFactoryWithHandlers<_EagerPanRecognizer>(
            () => _EagerPanRecognizer(debugOwner: this),
            (_EagerPanRecognizer instance) {
              // `down` keeps reported offsets faithful to the finger: the
              // touch slop consumed before the pan is recognised is reported
              // too, so the card never drifts away from the pointer.
              instance.dragStartBehavior = DragStartBehavior.down;
              instance.onStart = _onPanStart;
              instance.onUpdate = _onPanUpdate;
              instance.onEnd = (_) => _onPanEnd();
              instance.onCancel = _onPanEnd;
            },
          ),
        },
        child: Material(
          elevation: missing ? 1 : 4,
          shape: shape,
          color: missing
              ? colors.surfaceContainerHighest
              : colors.surfaceContainerHigh,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: missing ? null : widget.onTap,
            borderRadius:
                BorderRadius.circular(NotebookDumpCard.cornerRadius),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: NotebookDumpCard.minCardWidth,
                maxWidth: NotebookDumpCard.maxCardWidth,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
                child: missing
                    ? _MissingBody(onRemove: widget.onRemove)
                    : _DumpBody(dump: dump, onRemove: widget.onRemove),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DumpBody extends StatelessWidget {
  const _DumpBody({required this.dump, this.onRemove});

  final Dump dump;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final showDuration =
        dump.mode != DumpMode.textNote && dump.durationSeconds > 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              dumpModeIcon(dump.mode),
              size: 18,
              color: colors.primary,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                dump.title.isEmpty ? '(untitled)' : dump.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge,
              ),
            ),
            _RemoveButton(onRemove: onRemove),
          ],
        ),
        if (showDuration) ...[
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: Text(
              formatDumpDuration(dump.durationSeconds),
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _MissingBody extends StatelessWidget {
  const _MissingBody({this.onRemove});

  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disabled = theme.colorScheme.onSurface.withValues(alpha: 0.38);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.mic_off, size: 18, color: disabled),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            'Recording unavailable',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(
              color: disabled,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
        _RemoveButton(onRemove: onRemove),
      ],
    );
  }
}

class _RemoveButton extends StatelessWidget {
  const _RemoveButton({this.onRemove});

  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    if (onRemove == null) return const SizedBox(width: 6);
    return IconButton(
      icon: const Icon(Icons.close, size: 16),
      tooltip: 'Remove from notebook',
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      padding: EdgeInsets.zero,
      onPressed: onRemove,
    );
  }
}
