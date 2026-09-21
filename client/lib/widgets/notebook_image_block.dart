// SPDX-License-Identifier: AGPL-3.0-or-later
//
// An imported image floating on the notebook page.
//
// Interaction contract (Jeff's spec):
//  * A tap SELECTS the image, highlighting it like the lasso highlights ink
//    (accent border + soft glow).
//  * While selected, dragging from the middle MOVES it.
//  * While selected, four small tabs (one centred on each edge) RESIZE it.
//    Aspect ratio is locked: any tab scales the whole image proportionally.
//  * A small × above the top-right corner removes it (matches every other
//    block's affordance). Tapping elsewhere deselects via the host.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/notebook.dart';
import 'notebook_ink_canvas.dart';

/// Smallest rendered width, so an image cannot be shrunk into an
/// untouchable sliver.
const double kMinNotebookImageWidth = 48;

/// Hit size of each resize tab.
const double _tabSize = 28;

/// How far the selection chrome extends past the image on every side.
///
/// The selected widget grows by this inset and the host positions it at
/// (x - inset, y - inset): a Stack only hit-tests INSIDE its bounds even
/// with Clip.none, so tabs straddling the edge would paint but be dead on
/// the trailing sides without it.
const double kNotebookImageChromeInset = _tabSize / 2;

/// Visible size of each resize tab.
const double _tabVisual = 14;

class NotebookImageBlockWidget extends StatefulWidget {
  const NotebookImageBlockWidget({
    super.key,
    required this.block,
    required this.selected,
    required this.interactive,
    required this.onSelect,
    required this.onMoved,
    required this.onResized,
    required this.onCommit,
    required this.onRemove,
    required this.onDragActive,
  });

  final NotebookImageBlock block;

  /// Whether this image currently shows its move/resize chrome.
  final bool selected;

  /// False while draw mode owns the page: the image ignores every pointer
  /// so ink can be laid over it.
  final bool interactive;

  final VoidCallback onSelect;

  /// Per-step translation while dragging the middle.
  final ValueChanged<Offset> onMoved;

  /// A complete geometry replacement while dragging a resize tab.
  final ValueChanged<Rect> onResized;

  /// The gesture ended: persist the accumulated move/resize as ONE edit.
  final VoidCallback onCommit;

  final VoidCallback onRemove;

  /// Mirrors the dump card's contract: the page must not scroll under an
  /// active drag.
  final ValueChanged<bool> onDragActive;

  @override
  State<NotebookImageBlockWidget> createState() =>
      _NotebookImageBlockWidgetState();
}

class _NotebookImageBlockWidgetState extends State<NotebookImageBlockWidget> {
  /// Decoded lazily and cached: base64 decode per build would re-allocate
  /// the bytes on every repaint of the page.
  Uint8List? _bytes;
  String? _bytesFor;

  Uint8List _decodedBytes() {
    if (_bytesFor != widget.block.data || _bytes == null) {
      _bytes = base64Decode(widget.block.data);
      _bytesFor = widget.block.data;
    }
    return _bytes!;
  }

  /// Geometry at resize-gesture start, so the whole drag is computed from
  /// one anchor instead of accumulating rounding per step.
  Rect? _resizeStart;
  Offset _resizeAccum = Offset.zero;

  void _beginResize() {
    final NotebookImageBlock b = widget.block;
    _resizeStart = Rect.fromLTWH(b.x, b.y, b.width, b.height);
    _resizeAccum = Offset.zero;
    widget.onDragActive(true);
  }

  void _endResize() {
    _resizeStart = null;
    widget.onDragActive(false);
    widget.onCommit();
  }

  /// Applies one tab drag. [horizontal] names the dragged axis; [leading]
  /// is true for the left/top tab. Aspect ratio is LOCKED: the dragged
  /// edge's delta picks a scale factor and the whole image follows, with
  /// the opposite edge held in place so the image grows toward the drag.
  void _applyResize({
    required bool horizontal,
    required bool leading,
    required Offset delta,
  }) {
    final Rect? start = _resizeStart;
    if (start == null) return;
    _resizeAccum += delta;
    final double startEdge = horizontal ? start.width : start.height;
    double dragged = horizontal ? _resizeAccum.dx : _resizeAccum.dy;
    if (leading) dragged = -dragged;
    final double aspect = start.width / start.height;
    double width = horizontal
        ? startEdge + dragged
        : (startEdge + dragged) * aspect;
    width = math.max(kMinNotebookImageWidth, width);
    final double height = width / aspect;
    // The opposite edge stays anchored: dragging the left tab keeps the
    // right edge fixed, dragging the top tab keeps the bottom edge fixed.
    final double x = horizontal && leading ? start.right - width : start.left;
    final double y = !horizontal && leading ? start.bottom - height : start.top;
    widget.onResized(Rect.fromLTWH(x, y, width, height));
  }

  Widget _tab({
    required Key key,
    required bool horizontal,
    required bool leading,
  }) =>
      GestureDetector(
        key: key,
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => _beginResize(),
        onPanUpdate: (DragUpdateDetails d) => _applyResize(
          horizontal: horizontal,
          leading: leading,
          delta: d.delta,
        ),
        onPanEnd: (_) => _endResize(),
        onPanCancel: _endResize,
        child: SizedBox(
          width: _tabSize,
          height: _tabSize,
          child: Center(
            child: Container(
              width: horizontal ? _tabVisual / 2 + 4 : _tabVisual,
              height: horizontal ? _tabVisual : _tabVisual / 2 + 4,
              decoration: BoxDecoration(
                color: NotebookInkCanvas.inkColor,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: NotebookInkCanvas.backgroundColor,
                ),
              ),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final NotebookImageBlock block = widget.block;
    final Color accent = Theme.of(context).colorScheme.primary;

    final Widget image = Image.memory(
      _decodedBytes(),
      width: block.width,
      height: block.height,
      fit: BoxFit.fill,
      gaplessPlayback: true,
      // A block whose bytes no longer decode still occupies its place
      // honestly instead of vanishing.
      errorBuilder: (_, __, ___) => Container(
        width: block.width,
        height: block.height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: NotebookInkCanvas.inkColor),
        ),
        child: const Icon(
          Icons.broken_image_outlined,
          color: NotebookInkCanvas.inkColor,
        ),
      ),
    );

    if (!widget.interactive) return IgnorePointer(child: image);

    if (!widget.selected) {
      return GestureDetector(
        key: ValueKey<String>('notebook-image-${block.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelect,
        child: image,
      );
    }

    return SizedBox(
      width: block.width + 2 * kNotebookImageChromeInset,
      height: block.height + 2 * kNotebookImageChromeInset,
      child: Stack(
        children: <Widget>[
          // The image with its selection highlight; dragging it moves it.
          Positioned(
            left: kNotebookImageChromeInset,
            top: kNotebookImageChromeInset,
            child: GestureDetector(
              key: ValueKey<String>('notebook-image-${block.id}'),
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => widget.onDragActive(true),
              onPanUpdate: (DragUpdateDetails d) => widget.onMoved(d.delta),
              onPanEnd: (_) {
                widget.onDragActive(false);
                widget.onCommit();
              },
              onPanCancel: () {
                widget.onDragActive(false);
                widget.onCommit();
              },
              child: DecoratedBox(
                key: ValueKey<String>('notebook-image-selected-${block.id}'),
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  border: Border.all(color: accent, width: 2),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: accent.withValues(alpha: 0.35),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: image,
              ),
            ),
          ),
          // Resize tabs, centred on each edge of the image.
          Positioned(
            left: 0,
            top: kNotebookImageChromeInset + block.height / 2 - _tabSize / 2,
            child: _tab(
              key: ValueKey<String>('notebook-image-tab-left-${block.id}'),
              horizontal: true,
              leading: true,
            ),
          ),
          Positioned(
            left: kNotebookImageChromeInset + block.width - _tabSize / 2,
            top: kNotebookImageChromeInset + block.height / 2 - _tabSize / 2,
            child: _tab(
              key: ValueKey<String>('notebook-image-tab-right-${block.id}'),
              horizontal: true,
              leading: false,
            ),
          ),
          Positioned(
            left: kNotebookImageChromeInset + block.width / 2 - _tabSize / 2,
            top: 0,
            child: _tab(
              key: ValueKey<String>('notebook-image-tab-top-${block.id}'),
              horizontal: false,
              leading: true,
            ),
          ),
          Positioned(
            left: kNotebookImageChromeInset + block.width / 2 - _tabSize / 2,
            top: kNotebookImageChromeInset + block.height - _tabSize / 2,
            child: _tab(
              key: ValueKey<String>('notebook-image-tab-bottom-${block.id}'),
              horizontal: false,
              leading: false,
            ),
          ),
          // Remove, above the top-right corner like other blocks' ×.
          Positioned(
            left: kNotebookImageChromeInset + block.width - _tabSize / 2,
            top: 0,
            child: IconButton(
              key: ValueKey<String>('notebook-image-remove-${block.id}'),
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              color: NotebookInkCanvas.inkColor,
              onPressed: widget.onRemove,
              icon: const Icon(Icons.close),
            ),
          ),
        ],
      ),
    );
  }
}
