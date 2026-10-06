# Vendored SQLite amalgamation

Tangent builds SQLite from this checked-in source through `package:sqlite3`
3.7.0's native-assets hook. No prebuilt SQLite library is downloaded.

- SQLite version: **3.50.2** (`SQLITE_VERSION_NUMBER` 3050002)
- SQLite source id: `2025-06-28 14:00:48 2af157d77fb1304a74176eaee7fbc7c7e932d946bf25325e9c26c91db19e3079`
- Upstream archive: `https://sqlite.org/2025/sqlite-amalgamation-3500200.zip`
- Archive SHA-256: `387991de2834b5da2894119ff4173a9ea0779ea55ebcf53d9a40b24d1dc2484e`
- `sqlite3.c` SHA-256: `c9a0b6829b81d5f1b78392181f09744c818117a725667411d517b98149fcd3be`

SQLite 3.50.2 is the exact amalgamation selected by the default source-build
configuration in `sqlite3` 3.7.0. The package's documented `source: source`
hook is pointed directly at this file from `pubspec.yaml`.

SQLite is in the public domain; see `LICENSE.md` and the public-domain notice
at the top of `sqlite3.c`.