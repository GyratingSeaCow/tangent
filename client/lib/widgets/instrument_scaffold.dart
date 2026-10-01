// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/notebook_repository.dart';
import '../models/notebook.dart';
import '../screens/ask/ask_screen.dart';
import '../screens/dump/dumps_list_screen.dart';
import '../screens/notebook/notebook_editor_screen.dart';
import '../screens/notebook/notebook_list_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/todo/todo_list_screen.dart';
import '../services/create_requests.dart';
import '../theme/tangent_tokens.dart';
import 'top_nav_rail.dart';

/// Instrument Console v2 chrome: the top navigation rail on every top-level
/// screen, plus the global lime create key.
///
/// The rail is a JUMP BAR, not a tab stack: selecting a destination pops to
/// the root and pushes that destination's screen, so Android back always
/// walks out through a root the user knows. Deep-link routing in `_Router`
/// is untouched.
class InstrumentScaffold extends ConsumerWidget {
  const InstrumentScaffold({
    super.key,
    required this.root,
    this.appBar,
    required this.body,
    this.showCreateFab = true,
    this.floatingActionButton,
    this.maxContentWidth,
  });

  /// Wide-screen reading measure (Fold open, tablets, desktop). When set,
  /// the body is centred and capped at this width once the window is wider
  /// than it; narrower windows are untouched. Lists that WANT the full
  /// width (the Recordings/Notebooks/To Do roots) leave it null.
  static const double readingWidth = 700;

  /// Which rail destination this screen belongs to.
  final TangentRoot root;

  /// The screen's own app bar, rendered BELOW the rail.
  final PreferredSizeWidget? appBar;

  final Widget body;

  /// The global create key. Screens that need the space (the notebook
  /// editor's stylus canvas) switch it off.
  final bool showCreateFab;

  /// A screen-specific FAB override; mutually exclusive with
  /// [showCreateFab].
  final Widget? floatingActionButton;

  final double? maxContentWidth;

  static const Key createFabKey = Key('global-create-fab');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Column(
        children: [
          // Mockup order: status bar, app bar, THEN the rail. The app bar
          // owns the top inset.
          if (appBar != null)
            SafeArea(
              bottom: false,
              // An app bar in a Column gets UNBOUNDED height, which blows up
              // any bar whose `bottom:` uses flex (the notebook editor's
              // tool strip has an Expanded width slider). Pin it to the
              // height it already declares.
              child: MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: SizedBox(
                  height: appBar!.preferredSize.height,
                  child: appBar!,
                ),
              ),
            ),
          Container(
            color: TangentColors.sunken,
            child: SafeArea(
              top: appBar == null,
              bottom: false,
              child: TopNavRail(
                active: root,
                onSelect: (dest) => goToRoot(context, ref, dest),
              ),
            ),
          ),
          Expanded(
            child: maxContentWidth == null
                ? body
                : Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints:
                          BoxConstraints(maxWidth: maxContentWidth!),
                      child: body,
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: floatingActionButton ??
          (showCreateFab
              ? FloatingActionButton(
                  key: createFabKey,
                  tooltip: 'Create',
                  onPressed: () => showCreateSheet(context, ref),
                  child: const Icon(Icons.add),
                )
              : null),
    );
  }
}

/// Jump to a rail destination: back to the root, then push the target.
Future<void> goToRoot(
  BuildContext context,
  WidgetRef ref,
  TangentRoot dest,
) async {
  final NavigatorState nav = Navigator.of(context);
  final CreateRequests requests = ref.read(createRequestsProvider);
  // ONE navigator transaction: push the destination and remove everything
  // between it and the root. Flutter disposes the removed routes only after
  // the new route has finished animating, so the screen you were on stays
  // beneath the transition and Capture never flashes through. (popUntil
  // followed by push tore the old route out first and showed Home for the
  // length of the push animation.) The resulting stack is still
  // root + destination, so Android back walks out through Capture.
  bool rootOnly(Route<dynamic> route) => route.isFirst;
  switch (dest) {
    case TangentRoot.capture:
      nav.popUntil(rootOnly); // Capture IS the root: a plain pop home.
    case TangentRoot.recordings:
      // The Recordings list can pop with a create action (its long-standing
      // contract); forward it into the create funnel the Capture screen
      // listens on, exactly as its FAB flow always behaved.
      final DumpsCreateAction? action =
          await nav.pushAndRemoveUntil<DumpsCreateAction?>(
        MaterialPageRoute<DumpsCreateAction?>(
          builder: (_) => const DumpsListScreen(),
        ),
        rootOnly,
      );
      switch (action) {
        case DumpsCreateAction.textNote:
          requests.send(CreateRequest.textNote);
        case DumpsCreateAction.brainDump:
          requests.send(CreateRequest.recording);
        case DumpsCreateAction.meeting:
          requests.send(CreateRequest.meeting);
        case null:
          break;
      }
    case TangentRoot.notebooks:
      await nav.pushAndRemoveUntil<void>(
        MaterialPageRoute<void>(builder: (_) => const NotebookListScreen()),
        rootOnly,
      );
    case TangentRoot.todo:
      await nav.pushAndRemoveUntil<void>(
        MaterialPageRoute<void>(builder: (_) => const TodoListScreen()),
        rootOnly,
      );
    case TangentRoot.ask:
      await nav.pushAndRemoveUntil<void>(
        MaterialPageRoute<void>(builder: (_) => const AskScreen()),
        rootOnly,
      );
    case TangentRoot.settings:
      await nav.pushAndRemoveUntil<void>(
        MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
        rootOnly,
      );
  }
}

/// The global create sheet: one place to start anything.
///
/// Voice and text captures are DELIVERED to the Capture screen through the
/// create funnel (it owns the recording state machine); a notebook is
/// created and opened directly; a to-do lands on the list with the
/// quick-add field focused — each the same function its home-screen entry
/// point has always performed, raised from anywhere.
Future<void> showCreateSheet(BuildContext context, WidgetRef ref) async {
  final CreateRequest? choice = await showModalBottomSheet<CreateRequest>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const Key('create-sheet-recording'),
            leading: const Icon(Icons.psychology),
            title: const Text('Recording'),
            subtitle: const Text('Brain dump — transcribed and searchable'),
            onTap: () =>
                Navigator.of(sheetContext).pop(CreateRequest.recording),
          ),
          ListTile(
            key: const Key('create-sheet-meeting'),
            leading: const Icon(Icons.groups),
            title: const Text('Meeting'),
            subtitle: const Text('Secretary mode with action items'),
            onTap: () => Navigator.of(sheetContext).pop(CreateRequest.meeting),
          ),
          ListTile(
            key: const Key('create-sheet-text-note'),
            leading: const Icon(Icons.sticky_note_2),
            title: const Text('Text note'),
            onTap: () => Navigator.of(sheetContext).pop(CreateRequest.textNote),
          ),
          ListTile(
            key: const Key('create-sheet-notebook'),
            leading: const Icon(Icons.menu_book),
            title: const Text('Notebook'),
            onTap: () => Navigator.of(sheetContext).pop(CreateRequest.notebook),
          ),
          ListTile(
            key: const Key('create-sheet-todo'),
            leading: const Icon(Icons.check_box),
            title: const Text('To-do'),
            onTap: () => Navigator.of(sheetContext).pop(CreateRequest.todo),
          ),
        ],
      ),
    ),
  );
  if (choice == null) return;
  if (!context.mounted) return;
  await handleCreateSelection(context, ref, choice);
}

/// Routes a create-sheet choice. Split from [showCreateSheet] so tests can
/// drive it directly.
Future<void> handleCreateSelection(
  BuildContext context,
  WidgetRef ref,
  CreateRequest choice,
) async {
  // Capture BEFORE popping: popUntil disposes this screen's context.
  final NavigatorState nav = Navigator.of(context);
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  switch (choice) {
    case CreateRequest.recording:
    case CreateRequest.meeting:
    case CreateRequest.textNote:
      nav.popUntil((route) => route.isFirst);
      ref.read(createRequestsProvider).send(choice);
    case CreateRequest.notebook:
      // Same function as the Notebooks list's `+`: create empty, open it.
      try {
        final Notebook created =
            await ref.read(notebookRepositoryProvider).createNotebook();
        nav.popUntil((route) => route.isFirst);
        unawaited(
          nav.push<void>(
            MaterialPageRoute<void>(
              builder: (_) => NotebookEditorScreen(notebookId: created.id),
            ),
          ),
        );
      } catch (error) {
        messenger.showSnackBar(
          SnackBar(content: Text('Could not create notebook: $error')),
        );
      }
    case CreateRequest.todo:
      nav.popUntil((route) => route.isFirst);
      unawaited(
        nav.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const TodoListScreen(autofocusQuickAdd: true),
          ),
        ),
      );
  }
}
