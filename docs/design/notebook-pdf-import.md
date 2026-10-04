# Notebook PDF import and annotation

Imported PDFs are notebook canvas content, not embedded viewer widgets. The Insert menu creates one fixed `pdfPage` block per source page. Every block stores its canvas geometry and shared `documentId`; only the first page block stores the base64 source PDF. This keeps sync payloads proportional to the PDF size rather than page count. Source files are capped at 20 MiB before `readAsBytes`, with a visible refusal in the editor. Unknown or malformed blocks continue to round-trip as raw notebook blocks.

## Renderer choice

The client uses `pdfrx` 2.6.5's low-level document/page API. The package is actively maintained, published by a verified publisher, supports Android, and packages PDFium for native Flutter builds. It also exposes page dimensions and page rasterization independently of its viewer widgets, which is required for notebook-owned layout and an ink layer above the pages. The application does not mount `PdfViewer`.

## Rendering and cache

Import reads metadata only. A page widget requests a raster at the device pixel ratio (clamped to 3x and an 8000-pixel maximum dimension) when its canonical page rectangle enters the visible viewport plus a small prefetch margin. Rendered PNGs and one materialized source PDF are keyed by the import-time `documentId`, page number, and output dimensions in the OS temporary cache. The source base64 is decoded off the UI isolate at most once per cache instance; scrolling never hashes the whole PDF again. Concurrent requests coalesce, and cache entries older than seven days are pruned. When a page moves well outside the prefetch area, its `FileImage` is evicted. A 100-page notebook therefore mounts metadata for all pages but decodes only the nearby pages. Fold, rotation, and split-screen layout changes republish viewport geometry even when no scroll event fires.

PDF pages are fixed background blocks. Editable text, images, cards, and the existing `NotebookInkCanvas` are stacked above them, with ink topmost. New imports begin at the current content bottom plus the standard import spacing and preserve source page order and aspect ratio. The Insert menu exposes **Remove last imported PDF**; it removes the complete document group and offers snackbar undo without changing the established long-press contract.

## Export

When imported pages exist, PDF export first emits a canvas overview when non-PDF blocks or ink outside imported page rectangles exist, then emits one output page per imported page block in notebook order. It loads and composites one cached source-page raster at a time, decodes only image blocks intersecting that page, clips ordinary notebook blocks and ink to the page rectangle, encodes the composite as JPEG quality 85, and disposes decoded images before moving to the next page. The `pdf` package passes each JPEG through, so a 100-page document retains compressed page bytes rather than roughly a gigabyte of raw RGB/RGBA buffers.

Server text extraction treats `pdfPage` and image blocks as opaque. Their `data`, hash/document identifiers, and MIME metadata are absent from Ask FTS/chunks/prompts and MCP `get_notebook` text. Password-protected notebooks remain excluded by the pre-existing Ask, MCP, ink-search, and export gates.

## Limitations

- Imported and re-exported pages are rasterized. Original vector paths, searchable text, links, forms, and PDF metadata are not preserved.
- PDF page blocks are intentionally fixed; page reordering, cropping, rotation, and independent dragging are not supported.
- White notebook ink can have low contrast on light PDF pages; users can select a colored pen.
