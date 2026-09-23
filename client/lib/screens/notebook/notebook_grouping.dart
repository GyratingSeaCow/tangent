// SPDX-License-Identifier: AGPL-3.0-or-later
//
// How a filed notebook list is arranged.
//
// Extracted from the screen so the ordering rules are testable as plain data,
// without pumping a widget: what appears, in what order, and — most
// importantly — what a user who has never made a folder sees.
import '../../models/notebook.dart';

/// A folder, reduced to what the list needs.
class FolderSummary {
  const FolderSummary({required this.id, required this.name});

  final String id;
  final String name;
}

/// One block of the list: an optional header and its notebooks.
class NotebookSection {
  const NotebookSection({
    required this.title,
    required this.notebooks,
    this.folderId,
  });

  /// Null for the single flat section shown when no folders exist.
  final String? title;
  final String? folderId;
  final List<NotebookHeader> notebooks;

  bool get isEmpty => notebooks.isEmpty;
}

/// Label for notebooks that are not in any folder.
const String kUnfiledSectionTitle = 'No folder';

/// Arranges [notebooks] into sections.
///
/// Rules, in order of how much they matter:
///
/// 1. No folders at all means one unheaded section — a user who never opted
///    into folders sees exactly the flat list they had before.
/// 2. Folders sort alphabetically (case-insensitively) and come first.
/// 3. Empty folders still appear, so there is somewhere visible to file into.
/// 4. Unfiled notebooks come last, and that section is omitted when empty.
/// 5. Order inside a section is whatever the caller supplied (most recently
///    edited first), never re-sorted here.
/// 6. A notebook pointing at a folder that no longer exists is shown as
///    unfiled rather than dropped: losing sight of work is worse than
///    showing it in the wrong place.
List<NotebookSection> groupNotebooks({
  required List<NotebookHeader> notebooks,
  required List<FolderSummary> folders,
}) {
  if (folders.isEmpty) {
    // Rule 1. Note this deliberately also covers notebooks whose folder was
    // deleted: they land here rather than vanishing.
    return <NotebookSection>[
      NotebookSection(title: null, notebooks: List<NotebookHeader>.from(notebooks)),
    ];
  }

  final Set<String> knownFolderIds =
      folders.map((FolderSummary f) => f.id).toSet();

  final List<FolderSummary> sorted = List<FolderSummary>.from(folders)
    ..sort(
      (FolderSummary a, FolderSummary b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );

  final List<NotebookSection> sections = <NotebookSection>[
    for (final FolderSummary folder in sorted)
      NotebookSection(
        title: folder.name,
        folderId: folder.id,
        notebooks: notebooks
            .where((NotebookHeader n) => n.folderId == folder.id)
            .toList(growable: false),
      ),
  ];

  final List<NotebookHeader> unfiled = notebooks
      .where(
        (NotebookHeader n) =>
            n.folderId == null || !knownFolderIds.contains(n.folderId),
      )
      .toList(growable: false);

  if (unfiled.isNotEmpty) {
    sections.add(
      NotebookSection(title: kUnfiledSectionTitle, notebooks: unfiled),
    );
  }

  return sections;
}
