// SPDX-License-Identifier: AGPL-3.0-or-later
//
// How a filed dump list is arranged. Same rules as notebook_grouping.dart —
// the two lists are one mental model for the user, so the arrangement logic
// must never drift apart:
//
// 1. No folders at all means one unheaded section — a user who never opted
//    into folders sees exactly the flat list they had before.
// 2. Folders sort alphabetically (case-insensitively) and come first.
// 3. Empty folders still appear, so there is somewhere visible to file into.
// 4. Unfiled dumps come last, and that section is omitted when empty.
// 5. Order inside a section is whatever the caller supplied (most recent
//    first), never re-sorted here.
// 6. A dump pointing at a folder that no longer exists is shown as unfiled
//    rather than dropped: losing sight of work is worse than showing it in
//    the wrong place.
import '../../data/local_db.dart';
import '../notebook/notebook_grouping.dart' show FolderSummary;

/// One block of the dumps list: an optional header and its rows.
class DumpSection {
  const DumpSection({
    required this.title,
    required this.dumps,
    this.folderId,
  });

  /// Null for the single flat section shown when no folders exist.
  final String? title;
  final String? folderId;
  final List<DumpRow> dumps;

  bool get isEmpty => dumps.isEmpty;
}

/// Label for dumps that are not in any folder. Shared wording with the
/// notebooks list on purpose.
const String kUnfiledDumpSectionTitle = 'No folder';

List<DumpSection> groupDumps({
  required List<DumpRow> dumps,
  required List<FolderSummary> folders,
}) {
  if (folders.isEmpty) {
    // Rule 1 — also covers rows whose folder was deleted: they land here
    // rather than vanishing.
    return <DumpSection>[
      DumpSection(title: null, dumps: List<DumpRow>.from(dumps)),
    ];
  }

  final Set<String> knownFolderIds =
      folders.map((FolderSummary f) => f.id).toSet();

  final List<FolderSummary> sorted = List<FolderSummary>.from(folders)
    ..sort(
      (FolderSummary a, FolderSummary b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );

  final List<DumpSection> sections = <DumpSection>[
    for (final FolderSummary folder in sorted)
      DumpSection(
        title: folder.name,
        folderId: folder.id,
        dumps: dumps
            .where((DumpRow d) => d.folderId == folder.id)
            .toList(growable: false),
      ),
  ];

  final List<DumpRow> unfiled = dumps
      .where(
        (DumpRow d) =>
            d.folderId == null || !knownFolderIds.contains(d.folderId),
      )
      .toList(growable: false);

  if (unfiled.isNotEmpty) {
    sections.add(DumpSection(title: kUnfiledDumpSectionTitle, dumps: unfiled));
  }

  return sections;
}
