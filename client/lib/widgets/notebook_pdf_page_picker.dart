// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/notebook_pdf_import.dart';

const int _thumbnailMaxWidth = 144;
const int _thumbnailMaxHeight = 192;

/// Selects source pages before a picked PDF is inserted into a notebook.
class NotebookPdfPagePicker extends StatefulWidget {
  const NotebookPdfPagePicker({
    super.key,
    required this.picked,
    required this.loader,
  });

  final PickedPdf picked;
  final PdfPageRasterLoader loader;

  static Future<Set<int>?> show(
    BuildContext context, {
    required PickedPdf picked,
    required PdfPageRasterLoader loader,
  }) => showDialog<Set<int>>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) =>
        NotebookPdfPagePicker(picked: picked, loader: loader),
  );

  @override
  State<NotebookPdfPagePicker> createState() => _NotebookPdfPagePickerState();
}

class _NotebookPdfPagePickerState extends State<NotebookPdfPagePicker> {
  late final int _pageCount = widget.picked.pageSizes.length;
  late final Set<int> _selected = <int>{
    for (int page = 1; page <= _pageCount; page++) page,
  };
  late final String _sourceData = base64Encode(widget.picked.bytes);
  late final TextEditingController _rangeController = TextEditingController(
    text: _pageCount == 1 ? '1' : '1-$_pageCount',
  );
  late PdfPageRangeResult _range = parsePdfPageRange(
    _rangeController.text,
    pageCount: _pageCount,
  );

  @override
  void dispose() {
    _rangeController.dispose();
    super.dispose();
  }

  void _toggle(int page, bool selected) {
    setState(() {
      if (selected) {
        _selected.add(page);
      } else {
        _selected.remove(page);
      }
    });
  }

  void _rangeChanged(String value) {
    setState(() {
      _range = parsePdfPageRange(value, pageCount: _pageCount);
    });
  }

  void _applyRange() {
    if (!_range.isValid) return;
    setState(() {
      _selected
        ..clear()
        ..addAll(_range.pages);
    });
  }

  @override
  Widget build(BuildContext context) {
    final Size viewport = MediaQuery.sizeOf(context);
    final bool canImport = _range.isValid && _selected.isNotEmpty;
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 720,
          maxHeight: viewport.height * 0.9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
              child: Text(
                'Import ${widget.picked.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                '${_selected.length} of $_pageCount pages selected',
                key: const ValueKey('pdf-page-selection-count'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      key: const ValueKey('pdf-page-range'),
                      controller: _rangeController,
                      decoration: InputDecoration(
                        labelText: 'Pages',
                        hintText: '1-3,7,12-14',
                        errorText: _range.error,
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      textInputAction: TextInputAction.done,
                      onChanged: _rangeChanged,
                      onSubmitted: (_) => _applyRange(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.tonal(
                    key: const ValueKey('pdf-page-range-apply'),
                    onPressed: _range.isValid ? _applyRange : null,
                    child: const Text('Apply'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: Scrollbar(
                child: ListView.builder(
                  key: const ValueKey('pdf-page-list'),
                  itemCount: _pageCount,
                  itemBuilder: (BuildContext context, int index) {
                    final int page = index + 1;
                    final bool selected = _selected.contains(page);
                    return SizedBox(
                      height: 220,
                      child: Row(
                        children: <Widget>[
                          const SizedBox(width: 12),
                          Checkbox(
                            key: ValueKey<String>('pdf-page-checkbox-$page'),
                            value: selected,
                            onChanged: (bool? value) =>
                                _toggle(page, value ?? false),
                          ),
                          Expanded(
                            child: Center(
                              child: InkWell(
                                key: ValueKey<String>(
                                  'pdf-page-thumbnail-$page',
                                ),
                                onTap: () => _toggle(page, !selected),
                                child: Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: _PdfPageThumbnail(
                                    documentId: widget.picked.documentId,
                                    sourceData: _sourceData,
                                    pageNumber: page,
                                    pageSize: widget.picked.pageSizes[index],
                                    loader: widget.loader,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 96,
                            child: Text(
                              'Page $page',
                              key: ValueKey<String>('pdf-page-number-$page'),
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    key: const ValueKey('pdf-page-cancel'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('pdf-page-import'),
                    onPressed: canImport
                        ? () => Navigator.of(
                            context,
                          ).pop(Set<int>.unmodifiable(_selected))
                        : null,
                    child: const Text('Import'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PdfPageThumbnail extends StatefulWidget {
  const _PdfPageThumbnail({
    required this.documentId,
    required this.sourceData,
    required this.pageNumber,
    required this.pageSize,
    required this.loader,
  });

  final String documentId;
  final String sourceData;
  final int pageNumber;
  final Size pageSize;
  final PdfPageRasterLoader loader;

  @override
  State<_PdfPageThumbnail> createState() => _PdfPageThumbnailState();
}

class _PdfPageThumbnailState extends State<_PdfPageThumbnail> {
  FileImage? _provider;
  Object? _error;
  bool _loading = false;
  int _generation = 0;

  (int, int) _rasterSizeFor(Size pageSize) {
    final double scale = math.min(
      1,
      math.min(
        _thumbnailMaxWidth / pageSize.width,
        _thumbnailMaxHeight / pageSize.height,
      ),
    );
    return (
      (pageSize.width * scale).round().clamp(1, _thumbnailMaxWidth),
      (pageSize.height * scale).round().clamp(1, _thumbnailMaxHeight),
    );
  }

  (int, int) get _rasterSize => _rasterSizeFor(widget.pageSize);

  @override
  void initState() {
    super.initState();
    scheduleMicrotask(_load);
  }

  @override
  void didUpdateWidget(_PdfPageThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.documentId != widget.documentId ||
        oldWidget.pageNumber != widget.pageNumber ||
        oldWidget.pageSize != widget.pageSize ||
        oldWidget.loader != widget.loader) {
      _cancel(oldWidget);
      _releaseImage();
      scheduleMicrotask(_load);
    }
  }

  @override
  void dispose() {
    _cancel(widget);
    _generation++;
    final FileImage? provider = _provider;
    if (provider != null) unawaited(provider.evict());
    super.dispose();
  }

  void _cancel(_PdfPageThumbnail thumbnail) {
    if (!_loading || thumbnail.loader is! CancellablePdfPageRasterLoader) {
      return;
    }
    final (int width, int height) = _rasterSizeFor(thumbnail.pageSize);
    (thumbnail.loader as CancellablePdfPageRasterLoader).cancelPage(
      documentId: thumbnail.documentId,
      pageNumber: thumbnail.pageNumber,
      width: width,
      height: height,
    );
  }

  void _releaseImage() {
    final FileImage? provider = _provider;
    _generation++;
    _provider = null;
    _loading = false;
    _error = null;
    if (provider != null) unawaited(provider.evict());
  }

  Future<void> _load() async {
    if (!mounted || _loading || _provider != null) return;
    final int generation = ++_generation;
    final (int width, int height) = _rasterSize;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final File file = await widget.loader.loadPage(
        documentId: widget.documentId,
        sourceData: widget.sourceData,
        pageNumber: widget.pageNumber,
        width: width,
        height: height,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _provider = FileImage(file);
        _loading = false;
      });
    } on PdfRenderCancelledException {
      if (!mounted || generation != _generation) return;
      setState(() => _loading = false);
      unawaited(Future<void>.delayed(const Duration(milliseconds: 16), _load));
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final (int width, int height) = _rasterSize;
    return Container(
      width: width.toDouble(),
      height: height.toDouble(),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0x44333333)),
      ),
      child: switch ((_provider, _loading, _error)) {
        (final FileImage provider, _, _) => Image(
          image: provider,
          fit: BoxFit.fill,
          filterQuality: FilterQuality.low,
          gaplessPlayback: true,
        ),
        (_, true, _) => const Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
        (_, _, final Object _) => const Center(
          child: Icon(Icons.broken_image_outlined, color: Colors.black54),
        ),
        _ => const SizedBox.shrink(),
      },
    );
  }
}
