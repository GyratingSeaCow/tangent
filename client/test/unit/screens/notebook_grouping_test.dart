// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/screens/notebook/notebook_grouping.dart';

/// Filing is only useful if the list shows it.
///
/// The rules here are deliberate, and the first one protects every user who
/// never makes a folder: with no folders, the list stays exactly as flat as it
/// was before folders existed. Nobody gets a "No folder" header imposed on a
/// feature they never opted into.
void main() {
  Notebook nb(String id, {String? folderId, int updated = 0}) => Notebook(
        id: id,
        title: id,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: updated)),
        document: const NotebookDocument.empty(),
        ink: const NotebookInk.empty(),
        folderId: folderId,
      );

  group('notebook grouping', () {
    test('with no folders the list is flat and unheaded', () {
      final List<NotebookSection> sections = groupNotebooks(
        notebooks: <Notebook>[nb('a'), nb('b')],
        folders: const <FolderSummary>[],
      );

      expect(sections, hasLength(1));
      expect(
        sections.single.title,
        isNull,
        reason: 'a user with no folders must not see folder chrome',
      );
      expect(sections.single.notebooks.map((Notebook n) => n.id), <String>[
        'a',
        'b',
      ]);
    });

    test('folders come first, alphabetically, then unfiled', () {
      final List<NotebookSection> sections = groupNotebooks(
        notebooks: <Notebook>[
          nb('loose'),
          nb('work-1', folderId: 'f-work'),
          nb('home-1', folderId: 'f-home'),
        ],
        folders: const <FolderSummary>[
          FolderSummary(id: 'f-work', name: 'Work'),
          FolderSummary(id: 'f-home', name: 'Home'),
        ],
      );

      expect(
        sections.map((NotebookSection s) => s.title),
        <String?>['Home', 'Work', 'No folder'],
      );
      expect(sections.last.notebooks.single.id, 'loose');
    });

    test('an empty folder still appears so it can be filed into', () {
      final List<NotebookSection> sections = groupNotebooks(
        notebooks: <Notebook>[nb('loose')],
        folders: const <FolderSummary>[
          FolderSummary(id: 'f-work', name: 'Work'),
        ],
      );

      expect(sections.first.title, 'Work');
      expect(sections.first.notebooks, isEmpty);
      expect(
        sections.first.isEmpty,
        isTrue,
        reason: 'the screen needs to know to draw an empty-folder hint',
      );
    });

    test('order within a folder is preserved, not re-sorted', () {
      // The caller hands rows in most-recently-edited-first order; grouping
      // must not quietly re-sort them by title or id.
      final List<NotebookSection> sections = groupNotebooks(
        notebooks: <Notebook>[
          nb('zeta', folderId: 'f-work', updated: 30),
          nb('alpha', folderId: 'f-work', updated: 20),
          nb('mid', folderId: 'f-work', updated: 10),
        ],
        folders: const <FolderSummary>[
          FolderSummary(id: 'f-work', name: 'Work'),
        ],
      );

      expect(sections.single.notebooks.map((Notebook n) => n.id), <String>[
        'zeta',
        'alpha',
        'mid',
      ]);
    });

    test('the unfiled section is omitted when everything is filed', () {
      final List<NotebookSection> sections = groupNotebooks(
        notebooks: <Notebook>[nb('work-1', folderId: 'f-work')],
        folders: const <FolderSummary>[
          FolderSummary(id: 'f-work', name: 'Work'),
        ],
      );

      expect(sections.map((NotebookSection s) => s.title), <String?>['Work']);
    });

    test('a notebook filed into a deleted folder still appears', () {
      // Defensive: if a folder row vanishes without unfiling its contents, the
      // notebook must not disappear from the list. Losing sight of work is
      // worse than showing it unfiled.
      //
      // At least one folder must exist, or this never reaches the orphan
      // logic — an empty folder list short-circuits to the flat section and
      // would pass even if orphans were dropped.
      final List<NotebookSection> sections = groupNotebooks(
        notebooks: <Notebook>[
          nb('orphan', folderId: 'f-gone'),
          nb('work-1', folderId: 'f-work'),
        ],
        folders: const <FolderSummary>[
          FolderSummary(id: 'f-work', name: 'Work'),
        ],
      );

      expect(
        sections.expand((NotebookSection s) => s.notebooks).map((n) => n.id),
        contains('orphan'),
      );
      expect(
        sections.last.title,
        kUnfiledSectionTitle,
        reason: 'an orphan is shown as unfiled, not hidden',
      );
      expect(sections.last.notebooks.single.id, 'orphan');
    });

    test('folder names sort case-insensitively', () {
      final List<NotebookSection> sections = groupNotebooks(
        notebooks: const <Notebook>[],
        folders: const <FolderSummary>[
          FolderSummary(id: 'b', name: 'banana'),
          FolderSummary(id: 'a', name: 'Apple'),
        ],
      );

      expect(
        sections.map((NotebookSection s) => s.title),
        <String?>['Apple', 'banana'],
      );
    });
  });
}
