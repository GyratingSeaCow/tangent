// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A single imported PDF page on the notebook canvas. The widget is deliberately
// not a PDF viewer: it asks for one raster only while near the viewport, shows
// the cached file, and evicts the decoded FileImage after it scrolls away.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../models/notebook.dart';
import '../services/notebook_pdf_import.dart';

class NotebookPdfPageBlockWidget extends StatefulWidget {
  const NotebookPdfPageBlockWidget({
    super.key,
    required this.block,
    required this.sourceData,
    required this.loader,
    required this.visiblePageRect,
  });

  final NotebookPdfPageBlock block;
  final String? sourceData;
  final PdfPageRasterLoader loader;

  /// Visible editor viewport in canonical notebook coordinates.
  final ValueListenable<Rect> visiblePageRect;

  @override
  State<NotebookPdfPageBlockWidget> createState() =>
      _NotebookPdfPageBlockWidgetState();
}

class _NotebookPdfPageBlockWidgetState
    extends State<NotebookPdfPageBlockWidget> {
  FileImage? _provider;
  Object? _error;
  int _generation = 0;
  bool _loading = false;

  Rect get _pageRect => Rect.fromLTWH(
    widget.block.x,
    widget.block.y,
    widget.block.width,
    widget.block.height,
  );

  @override
  void initState() {
    super.initState();
    widget.visiblePageRect.addListener(_visibilityChanged);
    scheduleMicrotask(_visibilityChanged);
  }

  @override
  void didUpdateWidget(NotebookPdfPageBlockWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visiblePageRect != widget.visiblePageRect) {
      oldWidget.visiblePageRect.removeListener(_visibilityChanged);
      widget.visiblePageRect.addListener(_visibilityChanged);
    }
    if (oldWidget.block != widget.block ||
        oldWidget.sourceData != widget.sourceData ||
        oldWidget.loader != widget.loader) {
      _releaseImage();
    }
    scheduleMicrotask(_visibilityChanged);
  }

  @override
  void dispose() {
    widget.visiblePageRect.removeListener(_visibilityChanged);
    _generation++;
    unawaited(_provider?.evict() ?? Future<bool>.value(false));
    super.dispose();
  }

  void _visibilityChanged() {
    if (!mounted) return;
    final Rect visible = widget.visiblePageRect.value;
    // A modest prefetch margin avoids a blank flash at a page boundary while
    // keeping the render budget independent of total document page count.
    final bool wanted = visible.inflate(160).overlaps(_pageRect);
    if (!wanted) {
      _releaseImage();
      return;
    }
    if (_provider == null && !_loading && widget.sourceData != null) {
      unawaited(_load());
    }
  }

  void _releaseImage() {
    final FileImage? old = _provider;
    _generation++;
    if (old == null && !_loading && _error == null) return;
    if (mounted) {
      setState(() {
        _provider = null;
        _loading = false;
        _error = null;
      });
    }
    if (old != null) unawaited(old.evict());
  }

  Future<void> _load() async {
    final int generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final File file = await widget.loader.loadPage(
        sourceData: widget.sourceData!,
        pageNumber: widget.block.pageNumber,
        width: (widget.block.width * 2).round(),
        height: (widget.block.height * 2).round(),
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _provider = FileImage(file);
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    key: ValueKey<String>('notebook-pdf-page-${widget.block.id}'),
    width: widget.block.width,
    height: widget.block.height,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0x44333333)),
      ),
      child: switch ((_provider, _loading, _error, widget.sourceData)) {
        (final FileImage image, _, _, _) => Image(
          image: image,
          width: widget.block.width,
          height: widget.block.height,
          fit: BoxFit.fill,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
          errorBuilder: (_, Object error, StackTrace? stack) => _PageStatus(
            pageNumber: widget.block.pageNumber,
            message: 'PDF page unavailable',
          ),
        ),
        (_, true, _, _) => Center(
          child: SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(
              key: ValueKey<String>('notebook-pdf-loading-${widget.block.id}'),
              strokeWidth: 2,
            ),
          ),
        ),
        (_, _, final Object _, _) || (_, _, _, null) => _PageStatus(
          pageNumber: widget.block.pageNumber,
          message: 'PDF page unavailable',
        ),
        _ => _PageStatus(
          pageNumber: widget.block.pageNumber,
          message: 'PDF page ${widget.block.pageNumber}',
        ),
      },
    ),
  );
}

class _PageStatus extends StatelessWidget {
  const _PageStatus({required this.pageNumber, required this.message});

  final int pageNumber;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      message,
      key: ValueKey<String>('notebook-pdf-status-$pageNumber'),
      style: const TextStyle(color: Colors.black54),
    ),
  );
}
