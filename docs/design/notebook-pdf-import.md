# Notebook PDF import and annotation

Imported PDFs are notebook canvas content, not embedded viewer widgets. The Insert menu creates one fixed `pdfPage` block per source page. Every block stores its canvas geometry and shared `documentId`; only the first page block stores the base64 source PDF. This keeps sync payloads proportional to the PDF size rather than page count. Unknown or malformed blocks continue to round-trip as raw notebook blocks.

## Renderer choice

The client uses `pdfrx` 2.6.5's low-level document/page API. The package is actively maintained, published by a verified publisher, supports Android, and packages PDFium for native Flutter builds. It also exposes page dimensions and page rasterization independently of its viewer widgets, which is required for notebook-owned layout and an ink layer above the pages. The application does not mount `PdfViewer`.

## Rendering and cache

Import reads metadata only. A page widget requests a 2x raster when its canonical page rectangle enters the visible viewport plus a small prefetch margin. Rendered PNGs and one materialized source PDF are keyed by source hash, page number, and output dimensions in the OS temporary cache. Concurrent requests coalesce. When a page moves well outside the prefetch area, its `FileImage` is evicted; compressed cache files remain on disk. A 100-page notebook therefore mounts metadata for all pages but decodes only the nearby pages.

PDF pages are fixed background blocks. Editable text, images, cards, and the existing `NotebookInkCanvas` are stacked above them, with ink topmost. New imports begin at the current content bottom plus the standard import spacing and preserve source page order and aspect ratio.

## Export

When imported pages exist, PDF export emits one output page per imported page block in notebook order. It loads and composites one cached source-page raster at a time, clips ordinary notebook blocks and ink to that page's canvas rectangle, and disposes decoded images before moving to the next page.

## Limitations

- Imported and re-exported pages are rasterized at 2x logical resolution. Original vector paths, searchable text, links, forms, and PDF metadata are not preserved.
- PDF page blocks are intentionally fixed; page reordering, cropping, rotation, and independent dragging are not supported.
- White notebook ink can have low contrast on light PDF pages; users can select a colored pen.
- When a notebook contains imported PDF pages, export is page-oriented around those blocks. Non-PDF notebook blocks outside imported page rectangles are not emitted as separate overview pages.
