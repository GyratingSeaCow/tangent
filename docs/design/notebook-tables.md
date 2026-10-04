# Notebook tables

Notebook tables are durable `table` document blocks with sparse string cells.
The editor supports 1–100 rows and columns, paints only the visible grid cells,
and mounts one `TextField` only for the active cell.

## PDF follow-up

Table rendering is intentionally not included in the current single-page raster
PDF exporter. A 100×100 table is 12,000 canonical pixels wide, while the raster
exporter clamps each axis to 8,000 pixels and has no pagination. Painting a
partial viewport would silently lose cells; removing the clamp would create an
unsafe image allocation. PDF tables should ship only with tiled or paginated
rendering and tests that recover cells from the generated PDF. Markdown export
declares omitted tables rather than silently dropping them.