// SPDX-License-Identifier: AGPL-3.0-or-later
//
// One notebook page: typed text, checkboxes, floating recording cards and a
// handwriting layer, saved explicitly.
//
// Design contract: docs/superpowers/specs/2026-09-17-notebooks-design.md
//   * The page is BLACK and ink is WHITE (phase 1 has no colour picker), so
//     the typed content is rendered light-on-dark to match the ink layer.
//   * The pen size lives in THIS page's toolbar only — never global settings.
//   * A `dumpCard` block whose dump no longer exists renders as a disabled
//     "Recording unavailable" placeholder. It is never dropped, and the
//     notebook never mutates a dump row.
//   * Saving is explicit (Text Note convention); backing out dirty asks first.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/local_db.dart';
import '../../data/notebook_repository.dart';
import '../../models/dump.dart';
import '../../models/dump_mode.dart';
import '../../models/notebook.dart';
import '../../models/sync_status.dart';
import '../../services/notebook_persistence.dart';
import '../../widgets/dump_picker_sheet.dart';
import '../../widgets/notebook_dump_card.dart';
import '../../widgets/notebook_ink_canvas.dart';
import '../dump/dump_detail_screen.dart';
import '../dump/dumps_providers.dart';

/// Turns the ink canvas's opaque black backdrop into transparency so the layer
/// composites as "white ink only" over the notebook page.
///
/// The canvas is deliberately the TOP layer (it must receive the pointer in
/// draw mode, and ink belongs above the content you are annotating), but it
/// paints its own opaque black background. Mapping luminance onto alpha —
/// black backdrop -> alpha 0, white ink -> alpha 1 — keeps the settled layer
/// order while leaving the typed blocks and cards visible underneath.
const ColorFilter kNotebookInkCutout = ColorFilter.matrix(<double>[
  1, 0, 0, 0, 0, //
  0, 1, 0, 0, 0, //
  0, 0, 1, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
]);

/// Side of the square notebook canvas, in logical pixels.
///
/// "Infinite" in practice: at 1x this is ~13 phone screens across and ~26
/// down, and the viewer's boundary margin lets you drag past it. A finite
/// extent keeps stroke coordinates plain page coordinates, so existing
/// notebooks and their saved ink need no migration.
const double _canvasExtent = 5000;

/// Width of the typed-block column on the canvas.
///
/// Typed blocks stay in a readable column instead of stretching across the
/// whole canvas; handwriting and cards use the full area.
const double _pageColumnWidth = 720;

/// How far past the canvas edge the viewer may be dragged.
const double _canvasBoundaryMargin = 1000;

/// Insert actions offered by the editor's bottom-left menu.
enum _InsertAction { text, checkbox, dump, meeting, textNote }

class NotebookEditorScreen extends ConsumerStatefulWidget {
  const NotebookEditorScreen({super.key, required this.notebookId});

  final String notebookId;

  @override
  ConsumerState<NotebookEditorScreen> createState() =>
      _NotebookEditorScreenState();
}

class _NotebookEditorScreenState extends ConsumerState<NotebookEditorScreen> {
  static const Uuid _uuid = Uuid();

  final TextEditingController _title = TextEditingController();
  final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{};
  final GlobalKey<NotebookInkCanvasState> _canvasKey =
      GlobalKey<NotebookInkCanvasState>();

  /// Ordered block list. Text bodies live in [_controllers]; everything else
  /// (checked state, card coordinates, unknown payloads) lives here.
  List<NotebookBlock> _blocks = <NotebookBlock>[];
  List<InkStroke> _strokes = <InkStroke>[];

  Notebook? _notebook;
  bool _loading = true;
  String? _loadError;
  bool _dirty = false;
  bool _saving = false;
  bool _drawing = false;

  /// True while a card is being dragged, so the canvas holds still.
  bool _draggingCard = false;
  bool _erasing = false;
  double _penWidth = PenSizeControl.defaultPenWidth;

  /// Suppresses dirty-marking while the stored notebook is being poured into
  /// the controllers.
  bool _hydrating = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _title.dispose();
    for (final TextEditingController controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final Notebook? notebook = await ref
          .read(notebookRepositoryProvider)
          .getNotebook(widget.notebookId);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _notebook = notebook;
        if (notebook != null) _hydrate(notebook);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '$error';
      });
    }
  }

  void _hydrate(Notebook notebook) {
    _title.text = notebook.title;
    _blocks = List<NotebookBlock>.of(notebook.document.blocks);
    for (final NotebookBlock block in _blocks) {
      switch (block) {
        case NotebookTextBlock t:
          _controllerFor(t.id, t.text);
        case NotebookCheckboxBlock c:
          _controllerFor(c.id, c.text);
        case NotebookDumpCardBlock():
        case NotebookUnknownBlock():
          break;
      }
    }
    _strokes = List<InkStroke>.of(notebook.ink.strokes);
    _hydrating = false;
    _title.addListener(_markDirty);
  }

  /// Controllers are created with their initial text BEFORE the dirty
  /// listener is attached, so hydration never looks like an edit.
  TextEditingController _controllerFor(String id, String initial) =>
      _controllers.putIfAbsent(id, () {
        final TextEditingController controller =
            TextEditingController(text: initial);
        controller.addListener(_markDirty);
        return controller;
      });

  void _markDirty() {
    if (_hydrating || _dirty) return;
    setState(() => _dirty = true);
  }

  // -------------------------------------------------------------------
  // Block editing
  // -------------------------------------------------------------------

  void _addTextBlock() {
    final String id = _uuid.v4();
    _controllerFor(id, '');
    setState(() {
      _blocks = <NotebookBlock>[
        ..._blocks,
        NotebookTextBlock(id: id, text: ''),
      ];
      _dirty = true;
    });
  }

  void _addCheckboxBlock() {
    final String id = _uuid.v4();
    _controllerFor(id, '');
    setState(() {
      _blocks = <NotebookBlock>[
        ..._blocks,
        NotebookCheckboxBlock(id: id, text: ''),
      ];
      _dirty = true;
    });
  }

  void _toggleChecked(NotebookCheckboxBlock block, bool checked) {
    setState(() {
      _blocks = <NotebookBlock>[
        for (final NotebookBlock candidate in _blocks)
          if (candidate.id == block.id)
            block.copyWith(checked: checked)
          else
            candidate,
      ];
      _dirty = true;
    });
  }

  void _removeBlock(String id) {
    setState(() {
      _blocks = _blocks
          .where((NotebookBlock block) => block.id != id)
          .toList(growable: false);
      _dirty = true;
    });
    _controllers.remove(id)?.dispose();
  }

  /// The card reports interim pan positions AND the settled one through the
  /// same callback, and renders its own drag while the gesture is live.
  ///
  /// The parent still rebuilds on every report: once the gesture ends the card
  /// drops its internal drag offset and renders `widget.position`, so a parent
  /// that skipped the rebuild (for example because the page was already dirty)
  /// would snap the card back to where it started. Nothing is persisted here —
  /// the settled coordinates only reach storage on an explicit save.
  void _onCardMoved(String blockId, Offset position) {
    final int index =
        _blocks.indexWhere((NotebookBlock block) => block.id == blockId);
    if (index < 0) return;
    final NotebookBlock block = _blocks[index];
    if (block is! NotebookDumpCardBlock) return;
    if (block.x == position.dx && block.y == position.dy) return;
    setState(() {
      _blocks = <NotebookBlock>[
        for (int i = 0; i < _blocks.length; i++)
          if (i == index)
            block.copyWith(x: position.dx, y: position.dy)
          else
            _blocks[i],
      ];
      _dirty = true;
    });
  }

  /// Default drop point for a newly embedded card: a cascade down the page so
  /// several additions never land on top of each other.
  Offset _nextCardPosition(int ordinal) =>
      Offset(16 + (ordinal % 4) * 12, 24 + ordinal * 72);

  /// Imports recordings of one [mode] only.
  ///
  /// Each import entry filters the picker to its own kind: with 60 recordings
  /// on the device, an unfiltered list buries the three text notes Jeff was
  /// actually looking for.
  Future<void> _importDumps(List<Dump> dumps, DumpMode mode) => _addRecordings(
        dumps.where((Dump d) => d.mode == mode).toList(growable: false),
        noun: switch (mode) {
          DumpMode.brainDump => 'dumps',
          DumpMode.meeting => 'meetings',
          DumpMode.textNote => 'text notes',
        },
      );

  Future<void> _addRecordings(
    List<Dump> dumps, {
    String noun = 'recordings',
  }) async {
    final Set<String> embedded = <String>{
      for (final NotebookBlock block in _blocks)
        if (block is NotebookDumpCardBlock) block.dumpId,
    };
    final Set<String>? picked = await DumpPickerSheet.show(
      context,
      dumps: dumps,
      initiallySelected: embedded,
      noun: noun,
    );
    if (picked == null || !mounted) return;
    // Append only: unchecking an already-embedded recording in the picker is
    // not a removal instruction — the card's own × does that.
    final List<String> added = picked
        .where((String id) => !embedded.contains(id))
        .toList(growable: false);
    if (added.isEmpty) return;
    var ordinal = embedded.length;
    setState(() {
      _blocks = <NotebookBlock>[
        ..._blocks,
        for (final String dumpId in added)
          NotebookDumpCardBlock(
            id: _uuid.v4(),
            dumpId: dumpId,
            x: _nextCardPosition(ordinal).dx,
            y: _nextCardPosition(ordinal++).dy,
          ),
      ];
      _dirty = true;
    });
  }

  // -------------------------------------------------------------------
  // Saving / leaving
  // -------------------------------------------------------------------

  List<NotebookBlock> _composeBlocks() => <NotebookBlock>[
        for (final NotebookBlock block in _blocks)
          switch (block) {
            NotebookTextBlock t =>
              t.copyWith(text: _controllers[t.id]?.text ?? t.text),
            NotebookCheckboxBlock c =>
              c.copyWith(text: _controllers[c.id]?.text ?? c.text),
            NotebookBlock() => block,
          },
      ];

  Future<void> _save() async {
    final Notebook? current = _notebook;
    if (current == null || _saving) return;
    setState(() => _saving = true);
    final String typed = _title.text.trim();
    final Notebook updated = current.copyWith(
      title: typed.isEmpty ? current.title : typed,
      document: NotebookDocument(_composeBlocks()),
      ink: NotebookInk(List<InkStroke>.of(_strokes)),
    );
    try {
      // Route through NotebookPersistence, not the bare repository: it writes
      // the row AND publishes <id>.notebook.json into 'Tangent Notebooks', so
      // an uninstall no longer loses the notebook.
      await ref.read(notebookPersistenceProvider).saveNotebook(updated);
      if (!mounted) return;
      setState(() {
        _notebook = updated;
        _dirty = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notebook saved')),
      );
    } catch (error) {
      if (!mounted) return;
      // The edits stay on screen; only the failure is reported.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Notebook save failed: $error')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDiscard() async {
    final bool? discard = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('This notebook has unsaved edits.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  // -------------------------------------------------------------------
  // Rendering
  // -------------------------------------------------------------------

  Widget _buildBlockList() {
    // The canvas is what moves now: this column sits on the page at a fixed
    // size and is panned by the viewer, so it must not scroll on its own.
    // (A scrollable inside an unconstrained parent would also be unbounded.)
    //
    // Width is capped to a readable column rather than the full canvas width:
    // a text field stretched across 5000px puts its own centre far off-screen
    // and is unusable.
    return SizedBox(
      width: _pageColumnWidth,
      child: ListView(
        primary: false,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
      children: <Widget>[
        for (final NotebookBlock block in _blocks)
          switch (block) {
            NotebookTextBlock t => Padding(
                key: ValueKey<String>('notebook-text-row-${t.id}'),
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        key: ValueKey<String>('notebook-text-block-${t.id}'),
                        controller: _controllerFor(t.id, t.text),
                        maxLines: null,
                        style: _pageTextStyle,
                        cursorColor: NotebookInkCanvas.inkColor,
                        decoration: _pageInput('Write something…'),
                      ),
                    ),
                    _RemoveBlockButton(onPressed: () => _removeBlock(t.id)),
                  ],
                ),
              ),
            NotebookCheckboxBlock c => Padding(
                key: ValueKey<String>('notebook-checkbox-row-${c.id}'),
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Checkbox(
                      key: ValueKey<String>('notebook-checkbox-${c.id}'),
                      value: c.checked,
                      side: const BorderSide(
                        color: NotebookInkCanvas.inkColor,
                      ),
                      checkColor: NotebookInkCanvas.backgroundColor,
                      fillColor: WidgetStateProperty.resolveWith<Color?>(
                        (Set<WidgetState> states) =>
                            states.contains(WidgetState.selected)
                                ? NotebookInkCanvas.inkColor
                                : null,
                      ),
                      onChanged: (bool? checked) =>
                          _toggleChecked(c, checked ?? false),
                    ),
                    Expanded(
                      child: TextField(
                        key:
                            ValueKey<String>('notebook-checkbox-block-${c.id}'),
                        controller: _controllerFor(c.id, c.text),
                        maxLines: null,
                        style: _pageTextStyle,
                        cursorColor: NotebookInkCanvas.inkColor,
                        decoration: _pageInput('List item…'),
                      ),
                    ),
                    _RemoveBlockButton(onPressed: () => _removeBlock(c.id)),
                  ],
                ),
              ),
            // Cards live in the Stack layer above; unknown kinds are carried
            // through storage untouched and have nothing to render.
            NotebookBlock() => const SizedBox.shrink(),
          },
        ],
      ),
    );
  }

  static const TextStyle _pageTextStyle =
      TextStyle(color: NotebookInkCanvas.inkColor);

  InputDecoration _pageInput(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
          color: NotebookInkCanvas.inkColor.withValues(alpha: 0.45),
        ),
        border: InputBorder.none,
        isDense: true,
      );

  void _openDump(DumpRow row) {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => DumpDetailScreen(
            dumpId: row.id,
            audioPath: row.audioPath,
            durationSeconds: row.durationSeconds,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<DumpRow> rows =
        ref.watch(dumpsProvider).valueOrNull ?? const <DumpRow>[];
    final Map<String, DumpRow> rowsById = <String, DumpRow>{
      for (final DumpRow row in rows) row.id: row,
    };
    final List<Dump> dumps =
        rows.map(dumpFromRow).toList(growable: false);

    return PopScope(
      canPop: !_dirty && !_saving,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop || _saving) return;
        unawaited(_confirmDiscard());
      },
      child: Scaffold(
        appBar: AppBar(
          title: _loading || _notebook == null
              ? const Text('Notebook')
              : TextField(
                  key: const ValueKey<String>('notebook-title-field'),
                  controller: _title,
                  style: Theme.of(context).textTheme.titleLarge,
                  decoration: const InputDecoration(
                    hintText: 'Notebook title',
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
          actions: <Widget>[
            IconButton(
              icon: const Icon(Icons.draw),
              tooltip: _drawing ? 'Stop drawing' : 'Draw',
              isSelected: _drawing,
              onPressed: _notebook == null
                  ? null
                  : () => setState(() {
                        _drawing = !_drawing;
                        // The pen is the safe default whenever drawing
                        // resumes: a stranded eraser would make the next
                        // stroke delete work instead of adding it.
                        if (!_drawing) _erasing = false;
                      }),
            ),
            if (_drawing)
              IconButton(
                // An unlabelled mode is how you end up erasing when you meant
                // to draw, so the active tool is always shown as selected.
                icon: Icon(_erasing ? Icons.edit : Icons.auto_fix_normal),
                tooltip: _erasing ? 'Switch to pen' : 'Erase lines',
                isSelected: _erasing,
                onPressed: () => setState(() => _erasing = !_erasing),
              ),
            if (_drawing)
              IconButton(
                icon: const Icon(Icons.undo),
                tooltip: 'Undo stroke',
                onPressed: () => _canvasKey.currentState?.undoLastStroke(),
              ),
            IconButton(
              icon: const Icon(Icons.save),
              tooltip: 'Save notebook',
              onPressed: _notebook == null || _saving ? null : _save,
            ),
          ],
          bottom: _drawing
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(56),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: PenSizeControl(
                      value: _penWidth,
                      onChanged: (double width) =>
                          setState(() => _penWidth = width),
                    ),
                  ),
                )
              : null,
        ),
        bottomNavigationBar: _notebook == null
            ? null
            : BottomAppBar(
                // One menu in the bottom-left holds every insert action, so
                // adding an import does not keep widening a row of buttons.
                child: Row(
                  children: <Widget>[
                    PopupMenuButton<_InsertAction>(
                      key: const ValueKey('notebook-insert-menu'),
                      icon: const Icon(Icons.menu),
                      tooltip: 'Insert',
                      // Opens upward from the corner it lives in.
                      position: PopupMenuPosition.over,
                      onSelected: (_InsertAction action) {
                        switch (action) {
                          case _InsertAction.text:
                            _addTextBlock();
                          case _InsertAction.checkbox:
                            _addCheckboxBlock();
                          case _InsertAction.dump:
                            unawaited(
                              _importDumps(dumps, DumpMode.brainDump),
                            );
                          case _InsertAction.meeting:
                            unawaited(_importDumps(dumps, DumpMode.meeting));
                          case _InsertAction.textNote:
                            unawaited(_importDumps(dumps, DumpMode.textNote));
                        }
                      },
                      itemBuilder: (BuildContext context) =>
                          <PopupMenuEntry<_InsertAction>>[
                        const PopupMenuItem<_InsertAction>(
                          value: _InsertAction.text,
                          child: ListTile(
                            leading: Icon(Icons.notes),
                            title: Text('Text block'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuItem<_InsertAction>(
                          value: _InsertAction.checkbox,
                          child: ListTile(
                            leading: Icon(Icons.check_box_outlined),
                            title: Text('Checkbox'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuDivider(),
                        PopupMenuItem<_InsertAction>(
                          value: _InsertAction.dump,
                          child: ListTile(
                            leading: Icon(dumpModeIcon(DumpMode.brainDump)),
                            title: const Text('Dump'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        PopupMenuItem<_InsertAction>(
                          value: _InsertAction.meeting,
                          child: ListTile(
                            leading: Icon(dumpModeIcon(DumpMode.meeting)),
                            title: const Text('Meeting notes'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        PopupMenuItem<_InsertAction>(
                          value: _InsertAction.textNote,
                          child: ListTile(
                            leading: Icon(dumpModeIcon(DumpMode.textNote)),
                            title: const Text('Text note'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Insert',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
        body: _buildBody(rowsById),
      ),
    );
  }

  Widget _buildBody(Map<String, DumpRow> rowsById) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Notebook unavailable: $_loadError',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_notebook == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Notebook unavailable', textAlign: TextAlign.center),
        ),
      );
    }

    // One shared canvas, larger than the viewport, inside a pan/zoom viewer.
    //
    // The page used to be exactly one screenful: ink was Positioned.fill over
    // a separately scrolling ListView, so there was nowhere to draw past the
    // first screen — and scrolling the text slid it out from under its own
    // ink, because only one of the two layers moved.
    return InteractiveViewer(
      key: const ValueKey('notebook-canvas-viewer'),
      // An unconstrained child is what lets the canvas exceed the viewport.
      constrained: false,
      // Generous margin so you can always drag a little past your work.
      boundaryMargin: const EdgeInsets.all(_canvasBoundaryMargin),
      minScale: 0.2,
      maxScale: 4,
      // InteractiveViewer pans with ONE finger, which would fight the pen.
      // While drawing, the finger inks and only two-finger pinch still moves
      // the page.
      panEnabled: !_drawing && !_draggingCard,
      scaleEnabled: !_draggingCard,
      child: SizedBox(
        width: _canvasExtent,
        height: _canvasExtent,
        child: Stack(
          children: <Widget>[
            // Bottom: the page itself — black, per the phase-1 ink contract.
            // Filling paints the whole canvas; the typed column inside is
            // left-aligned at its own readable width rather than stretched.
            Positioned.fill(
              child: ColoredBox(
                color: NotebookInkCanvas.backgroundColor,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: _buildBlockList(),
                ),
              ),
            ),
            // Middle: floating recording cards. Each is a Positioned, so they
            // MUST be direct children of this Stack.
            for (final NotebookBlock block in _blocks)
              if (block is NotebookDumpCardBlock)
                NotebookDumpCard(
                  key: ValueKey<String>('notebook-card-${block.id}'),
                  dump: rowsById[block.dumpId] == null
                      ? null
                      : dumpFromRow(rowsById[block.dumpId]!),
                  position: Offset(block.x, block.y),
                  onPositionChanged: (Offset position) =>
                      _onCardMoved(block.id, position),
                  onTap: rowsById[block.dumpId] == null
                      ? null
                      : () => _openDump(rowsById[block.dumpId]!),
                  onRemove: () => _removeBlock(block.id),
                  onDragActive: (bool dragging) {
                    if (_draggingCard == dragging) return;
                    setState(() => _draggingCard = dragging);
                  },
                ),
            // Top: the ink layer. It ignores pointers unless draw mode is on,
            // so typing and card dragging work normally the rest of the time.
            Positioned.fill(
              child: ColorFiltered(
                colorFilter: kNotebookInkCutout,
                child: NotebookInkCanvas(
                  key: _canvasKey,
                  strokes: _strokes,
                  drawingEnabled: _drawing,
                  erasing: _erasing,
                  penWidth: _penWidth,
                  onStrokesChanged: (List<InkStroke> strokes) {
                    setState(() {
                      _strokes = List<InkStroke>.of(strokes);
                      _dirty = true;
                    });
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RemoveBlockButton extends StatelessWidget {
  const _RemoveBlockButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
        icon: const Icon(Icons.close, size: 16),
        color: NotebookInkCanvas.inkColor.withValues(alpha: 0.6),
        tooltip: 'Remove block',
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        padding: EdgeInsets.zero,
        onPressed: onPressed,
      );
}

/// Adapts a stored dump row to the presentation model the notebook widgets
/// take. Unknown wire values degrade instead of throwing: a row the notebook
/// cannot classify still deserves to render.
Dump dumpFromRow(DumpRow row) => Dump(
      id: row.id,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      mode: DumpMode.values.firstWhere(
        (DumpMode mode) => mode.wireValue == row.mode,
        orElse: () => DumpMode.brainDump,
      ),
      durationSeconds: row.durationSeconds,
      title: row.title,
      transcript: row.transcript,
      audioPath: row.audioPath,
      audioSizeBytes: row.audioSizeBytes,
      syncStatus: SyncStatus.values.firstWhere(
        (SyncStatus status) => status.wireValue == row.syncStatus,
        orElse: () => SyncStatus.localOnly,
      ),
      syncAttempts: row.syncAttempts,
      lastSyncError: row.lastSyncError,
    );
