// SPDX-License-Identifier: AGPL-3.0-or-later
//
// One notebook page: typed text, checkboxes, floating recording cards and a
// handwriting layer, saved explicitly.
//
//   * The page is BLACK and ink is WHITE (phase 1 has no colour picker), so
//     the typed content is rendered light-on-dark to match the ink layer.
//   * The pen size lives in THIS page's toolbar only — never global settings.
//   * A `dumpCard` block whose dump no longer exists renders as a disabled
//     "Recording unavailable" placeholder. It is never dropped, and the
//     notebook never mutates a dump row.
//   * Saving is explicit (Text Note convention); backing out dirty asks first.
import 'dart:async';
import 'dart:convert' show base64Encode;
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/local_db.dart';
import '../../data/notebook_repository.dart';
import '../../models/dump.dart';
import '../../models/dump_mode.dart';
import '../../models/notebook.dart';
import '../../models/notebook_ruling.dart';
import '../../models/sync_status.dart';
import '../../services/image_file_picker.dart';
import '../../services/ink_search.dart';
import '../../services/notebook_persistence.dart';
import '../../widgets/dump_picker_sheet.dart';
import '../../widgets/ink_palette_popup.dart';
import '../../widgets/notebook_dump_card.dart';
import '../../widgets/notebook_image_block.dart';
import '../../widgets/notebook_ink_canvas.dart';
import '../dump/dump_detail_screen.dart';
import '../dump/dumps_providers.dart';
import '../settings/handwriting_search_section.dart'
    show handwritingSearchEnabledProvider;
import 'notebook_find_bar.dart';

/// The footprint the lasso tests [block] against, in canonical page px.
///
/// Text and checkbox rows are MEASURED via [measureKey]: the laid-out
/// [RenderBox] is the row the user actually sees, so a wide row is caught
/// across its whole width instead of a nominal 300px slice. The rows lay out
/// inside the FittedBox's canonical-width child, so a RenderBox size is
/// already canonical — no scale conversion. Images know their real size from
/// the model. Anything unmeasurable (no key, key not attached to a laid-out
/// element) and every dump card falls back to [_nominalBlockFootprint] —
/// the safety net, never a crash.
@visibleForTesting
Size lassoBlockFootprint(NotebookBlock block, GlobalKey? measureKey) {
  if (block is NotebookImageBlock) return Size(block.width, block.height);
  if (block is NotebookTextBlock || block is NotebookCheckboxBlock) {
    final RenderObject? box = measureKey?.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize) return box.size;
  }
  return _nominalBlockFootprint;
}

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

/// Inset of the page's content from its top-left corner.
const double _pagePadding = 12;

/// Vertical step between blocks that have never been moved.
const double _unplacedBlockSpacing = 72;

/// Vertical gap between the current content bottom and an imported item.
const double _importSpacing = 24;

/// Nominal height reserved for a block when computing the content bottom.
const double _importBlockHeight = 90;

/// Spacing between consecutive imported audio cards.
const double _importCardSpacing = 104;

/// How a picked dump lands on the page.
enum _ImportShape { card, text }

/// Width of the typed-block column on the canvas.
///
/// Typed blocks stay in a readable column instead of stretching across the
/// whole canvas; handwriting and cards use the full area.
const double _pageColumnWidth = 720;

/// Floor for a block's width, so a block dragged far right stays usable.
const double _minBlockWidth = 160;

/// Fallback lasso footprint for a block whose real rendered size cannot be
/// measured, in canonical page px.
///
/// This is the safety net: a row not currently laid out falls back here
/// rather than crashing. It is also the PINNED footprint for dump cards —
/// Jeff tuned the 40% catch threshold on hardware against this box, and the
/// card tests pin loops at its exact 300px span, so cards deliberately have
/// no measure key.
const Size _nominalBlockFootprint = Size(300, 90);

/// Insert actions offered by the editor's bottom-left menu.
enum _InsertAction {
  text,
  checkbox,
  dump,
  meeting,
  textNote,
  image,
  cycleRuling,
  recentre
}

class NotebookEditorScreen extends ConsumerStatefulWidget {
  const NotebookEditorScreen({
    super.key,
    required this.notebookId,
    this.initialFindQuery,
  });

  final String notebookId;

  /// Deep link from the home screen's search: opens the editor with the find
  /// bar populated with this query and the FIRST match current (spec: a tap
  /// on a search result lands "at the top of the ctrl+f results"). Null (the
  /// ordinary open) mounts no find bar.
  final String? initialFindQuery;

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

  /// One measurement key per movable text/checkbox row, attached to the
  /// row's laid-out [SizedBox] so the lasso can read the footprint the user
  /// actually sees instead of the nominal guess. Images know their size from
  /// the model and dump cards stay on the nominal box (see
  /// [_nominalBlockFootprint]), so neither gets a key.
  final Map<String, GlobalKey> _blockMeasureKeys = <String, GlobalKey>{};

  GlobalKey _measureKeyFor(String id) =>
      _blockMeasureKeys.putIfAbsent(id, GlobalKey.new);

  /// Ordered block list. Text bodies live in [_controllers]; everything else
  /// (checked state, card coordinates, unknown payloads) lives here.
  List<NotebookBlock> _blocks = <NotebookBlock>[];
  List<InkStroke> _strokes = <InkStroke>[];

  Notebook? _notebook;

  /// How the page is ruled. Mirrors the notebook's stored value so the painter
  /// can rebuild without re-reading the database on every frame.
  NotebookRuling _ruling = NotebookRuling.blank;
  bool _loading = true;
  String? _loadError;
  bool _dirty = false;
  bool _saving = false;
  bool _drawing = false;

  /// True while a card is being dragged, so the canvas holds still.
  bool _draggingCard = false;

  /// Vertical position of the page, so it can be scrolled back to the top.
  final ScrollController _pageScroll = ScrollController();
  bool _erasing = false;

  /// Lasso mode: pointer input selects instead of drawing.
  bool _lassoing = false;

  /// True while the lasso selection is non-empty; enables the delete action.
  bool _lassoSelection = false;

  /// Ids of blocks (text, checkbox, recording cards) caught by the last
  /// lasso loop. They move and delete together with the selected ink.
  final Set<String> _lassoBlockIds = <String>{};

  /// The image whose move/resize chrome is showing, or null. One at a time:
  /// the chrome is modal enough that two selected images would fight over
  /// the page's gesture space.
  String? _selectedImageId;

  /// The instrument the next stroke uses.
  InkTool _tool = InkTool.pen;

  /// Each tool keeps its own ink for the session, so switching pen →
  /// highlighter → pen returns to the colour you were writing in.
  InkColor _penColour = InkColor.white;
  InkColor _highlighterColour = InkColor.yellow;

  InkColor get _activeColour =>
      _tool == InkTool.highlighter ? _highlighterColour : _penColour;

  double _penWidth = PenSizeControl.defaultPenWidth;

  /// The fountain nib is the default (Jeff's contract, 2026-09-22): it is
  /// the pen actually used; ballpoint was default only by being first.
  PenStyle _penStyle = PenStyle.fountain;

  /// True while a stylus is in contact or within its trailing window. The
  /// page holds still so a resting palm cannot scroll it mid-word.
  bool _stylusActive = false;

  // ---- Find (Ctrl+F over handwriting and typed blocks) ----

  /// Whether the find bar is mounted. Opened by the toolbar's search icon or
  /// by an [NotebookEditorScreen.initialFindQuery] deep link.
  bool _findOpen = false;

  /// The query text. Owned here (not by the bar) so a deep-linked query
  /// arrives already populated.
  final TextEditingController _findQuery = TextEditingController();

  /// Matches for the live query, in reading order (the service's contract).
  List<InkMatch> _findMatches = const <InkMatch>[];

  /// Index into [_findMatches] of the CURRENT match.
  int _findIndex = 0;

  /// Guards against out-of-order search responses: only the newest query's
  /// results may land, or fast typing could paint a stale result set.
  int _findGeneration = 0;

  /// The page scale the last layout used, captured so scroll-to-match can
  /// convert a match's canonical-page bbox into scroll offset.
  double _pageScale = 1.0;

  /// Suppresses dirty-marking while the stored notebook is being poured into
  /// the controllers.
  bool _hydrating = true;

  @override
  void initState() {
    super.initState();
    final String? deepLinked = widget.initialFindQuery;
    if (deepLinked != null && deepLinked.trim().isNotEmpty) {
      // Deep link from the home screen's search: the bar opens populated;
      // the search itself runs once the notebook has loaded (see _load).
      _findOpen = true;
      _findQuery.text = deepLinked;
    }
    unawaited(_load());
  }

  @override
  void dispose() {
    _pageScroll.dispose();
    _title.dispose();
    _findQuery.dispose();
    for (final TextEditingController controller in _controllers.values) {
      controller.dispose();
    }
    for (final FocusNode node in _focusNodes.values) {
      node.dispose();
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
      // The deep-linked find runs only now: the search reads the db, but
      // the scroll-to needs the page laid out, which needs the load done.
      if (notebook != null && _findOpen) {
        unawaited(_runFind(_findQuery.text));
      }
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
        case NotebookImageBlock():
        case NotebookUnknownBlock():
          break;
      }
    }
    _strokes = List<InkStroke>.of(notebook.ink.strokes);
    _ruling = notebook.ruling;
    // Each notebook reopens with ITS last nib (personal notebooks live in
    // fountain, others in ballpoint). Null — never recorded — keeps the
    // fountain default the field initialised with.
    _penStyle = notebook.lastPenStyle ?? _penStyle;
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

  /// Focus nodes live beside the controllers so a newly inserted list item
  /// can take the caret immediately. Created lazily and disposed with the
  /// block, exactly like its controller.
  final Map<String, FocusNode> _focusNodes = <String, FocusNode>{};

  FocusNode _focusFor(String id) => _focusNodes.putIfAbsent(id, () {
        final FocusNode node = FocusNode();
        // Remember the last block that held the caret. Read at insert time,
        // by which point the menu has taken focus away from the field.
        node.addListener(() {
          if (node.hasFocus) _lastFocusedBlockId = id;
        });
        return node;
      });

  void _markDirty() {
    if (_hydrating || _dirty) return;
    setState(() => _dirty = true);
  }

  // -------------------------------------------------------------------
  // Find in notebook
  // -------------------------------------------------------------------

  /// Every stroke any match covers — the canvas bands them all.
  Set<String> get _findHighlightIds => <String>{
        for (final InkMatch match in _findMatches) ...match.strokeIds,
      };

  /// The CURRENT match's strokes. Empty for a typed-block match (its
  /// [InkMatch.strokeIds] is empty): scroll-to only, no ink highlight.
  Set<String> get _findCurrentIds => _findMatches.isEmpty
      ? const <String>{}
      : _findMatches[_findIndex].strokeIds.toSet();

  void _openFind() {
    if (_findOpen) return;
    setState(() => _findOpen = true);
  }

  /// Close clears EVERYTHING: bar, query, matches, highlights. A closed
  /// find that left bands on the page would read as stuck marker.
  void _closeFind() {
    setState(() {
      _findOpen = false;
      _findQuery.clear();
      _findMatches = const <InkMatch>[];
      _findIndex = 0;
      // Orphan any in-flight search so its stale results cannot land on
      // the now-closed bar.
      _findGeneration++;
    });
  }

  Future<void> _runFind(String query) async {
    final int generation = ++_findGeneration;
    final List<InkMatch> matches = query.trim().isEmpty
        ? const <InkMatch>[]
        : await ref
            .read(inkSearchProvider)
            .searchInNotebook(widget.notebookId, query);
    // Only the NEWEST query's results may land; fast typing must not paint
    // a stale result set over a fresher one.
    if (!mounted || generation != _findGeneration || !_findOpen) return;
    setState(() {
      _findMatches = matches;
      _findIndex = 0;
    });
    if (matches.isNotEmpty) _scrollToCurrentMatch();
  }

  /// Steps the current match by [delta] (+1 next, -1 prev), wrapping at both
  /// ends — matches are already in reading order, so this is a plain walk.
  void _findStep(int delta) {
    final int count = _findMatches.length;
    if (count == 0) return;
    setState(() => _findIndex = (_findIndex + delta + count) % count);
    _scrollToCurrentMatch();
  }

  /// Brings the current match's bbox into view, roughly a third down the
  /// viewport so surrounding context shows above and below it.
  ///
  /// Post-frame: a deep-linked find runs before the page's first layout, and
  /// the scroll controller has no clients (and no extent) until it settles.
  void _scrollToCurrentMatch() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _findMatches.isEmpty || !_pageScroll.hasClients) return;
      final InkMatch match = _findMatches[_findIndex];
      final ScrollPosition position = _pageScroll.position;
      // The bbox lives in canonical page space; the viewport shows the page
      // scaled by [_pageScale] (see the LayoutBuilder in _buildBody).
      final double target = (match.bbox.top * _pageScale -
              position.viewportDimension / 3)
          .clamp(0.0, position.maxScrollExtent);
      unawaited(
        _pageScroll.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
        ),
      );
    });
  }

  // -------------------------------------------------------------------
  // Block editing
  // -------------------------------------------------------------------

  /// The block the caret is in, or null when nothing is focused.
  ///
  /// Remembered on every focus change rather than read on demand: opening the
  /// insert menu moves focus to the menu itself, so by the time an item is
  /// selected the field has already lost it and a live read always answers
  /// "nothing focused".
  String? _lastFocusedBlockId;

  /// Where a newly inserted block belongs.
  ///
  /// Directly after the block being edited, matching what Enter already does
  /// in a checkbox list. Appending to the very end scatters a page written
  /// top-to-bottom: the user is working mid-document and the new block appears
  /// far below, often off screen.
  ///
  /// With nothing focused there is no "here" to insert at, so the end of the
  /// page is the only answer that does not move the user somewhere they did
  /// not ask to go.
  int get _insertionIndex {
    final String? focused = _lastFocusedBlockId;
    if (focused == null) return _blocks.length;
    final int index =
        _blocks.indexWhere((NotebookBlock block) => block.id == focused);
    return index < 0 ? _blocks.length : index + 1;
  }

  /// Cycles the page ruling and marks the notebook dirty so the choice is
  /// saved and reaches the user's other devices.
  void _cycleRuling() {
    const List<NotebookRuling> order = <NotebookRuling>[
      NotebookRuling.blank,
      NotebookRuling.small,
      NotebookRuling.medium,
    ];
    final int next = (order.indexOf(_ruling) + 1) % order.length;
    setState(() {
      _ruling = order[next];
      _dirty = true;
    });
  }

  void _addTextBlock() {
    final String id = _uuid.v4();
    _controllerFor(id, '');
    final int at = _insertionIndex;
    setState(() {
      _blocks = <NotebookBlock>[
        ..._blocks.take(at),
        // Unplaced (x/y null) so it flows beneath its neighbour rather than
        // landing on top of it at identical coordinates.
        NotebookTextBlock(id: id, text: ''),
        ..._blocks.skip(at),
      ];
      _dirty = true;
    });
  }

  void _addCheckboxBlock() {
    final String id = _uuid.v4();
    _controllerFor(id, '');
    final int at = _insertionIndex;
    setState(() {
      _blocks = <NotebookBlock>[
        ..._blocks.take(at),
        NotebookCheckboxBlock(id: id, text: ''),
        ..._blocks.skip(at),
      ];
      _dirty = true;
    });
  }

  /// Starts a new checkbox item below [source], as Enter does in any list
  /// editor.
  ///
  /// Jeff: "when you are in the text area of a checkbox item, you can hit
  /// enter and it will go into another checkbox list item, not expand the
  /// box." A multi-line field is right for prose but wrong for a list, where
  /// Enter means "next item".
  ///
  /// Enter on an ALREADY EMPTY item ends the list instead — the universal
  /// escape hatch, and without it there is no way to stop adding items.
  void _splitCheckboxBlock(NotebookCheckboxBlock source) {
    final int index =
        _blocks.indexWhere((NotebookBlock block) => block.id == source.id);
    if (index < 0) return;

    if (_controllerFor(source.id, source.text).text.isEmpty) {
      _removeBlock(source.id);
      return;
    }

    final String id = _uuid.v4();
    _controllerFor(id, '');
    setState(() {
      _blocks = <NotebookBlock>[
        ..._blocks.take(index + 1),
        // Unplaced (x/y null) so it flows directly beneath its source rather
        // than landing on top of it at identical coordinates.
        NotebookCheckboxBlock(id: id, text: ''),
        ..._blocks.skip(index + 1),
      ];
      _dirty = true;
    });
    // Move the caret into the new item so typing continues uninterrupted.
    _focusFor(id).requestFocus();
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
    _focusNodes.remove(id)?.dispose();
    // A deleted block must not keep steering where new blocks land; its id
    // would never match again and the insert would silently go to the end.
    if (_lastFocusedBlockId == id) _lastFocusedBlockId = null;
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

    // Audio bubble or text? Asked AFTER picking so one answer covers the
    // whole batch, and nothing lands until the user has answered.
    final _ImportShape? shape = await _askImportShape();
    if (shape == null || !mounted) return;

    // Content-aware insert: everything new starts below the lowest existing
    // content (blocks AND ink), never on top of what is already there.
    double insertY = _contentBottom() + _importSpacing;
    final Map<String, Dump> dumpsById = <String, Dump>{
      for (final Dump dump in dumps) dump.id: dump,
    };

    setState(() {
      final List<NotebookBlock> newBlocks = <NotebookBlock>[];
      for (final String dumpId in added) {
        switch (shape) {
          case _ImportShape.card:
            newBlocks.add(
              NotebookDumpCardBlock(
                id: _uuid.v4(),
                dumpId: dumpId,
                x: _pagePadding + 4,
                y: insertY,
              ),
            );
            insertY += _importCardSpacing;
          case _ImportShape.text:
            final Dump? dump = dumpsById[dumpId];
            final String? transcript = dump?.transcript?.trim();
            // Honest fallback: an empty text box would read as a broken
            // import, so a missing transcript says so in the box.
            final String text = (transcript == null || transcript.isEmpty)
                ? '(no transcript for "${dump?.title ?? dumpId}")'
                : transcript;
            final String id = _uuid.v4();
            _controllerFor(id, text);
            newBlocks.add(
              NotebookTextBlock(
                id: id,
                text: text,
                x: _pagePadding + 4,
                y: insertY,
              ),
            );
            // Transcripts vary in length; leave room proportional to the
            // text so consecutive imports do not overlap each other.
            insertY += _importSpacing + (text.length / 40).ceil() * 24.0;
        }
      }
      _blocks = <NotebookBlock>[..._blocks, ...newBlocks];
      _dirty = true;
    });
  }

  /// Asks whether the import lands as audio bubbles or transcript text.
  Future<_ImportShape?> _askImportShape() => showModalBottomSheet<_ImportShape>(
        context: context,
        builder: (BuildContext sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                key: const ValueKey<String>('import-as-card'),
                leading: const Icon(Icons.graphic_eq),
                title: const Text('Audio bubble'),
                subtitle: const Text('A playable card you can drag around'),
                onTap: () => Navigator.of(sheetContext).pop(_ImportShape.card),
              ),
              ListTile(
                key: const ValueKey<String>('import-as-text'),
                leading: const Icon(Icons.notes),
                title: const Text('Text'),
                subtitle: const Text('The transcript, in an editable text box'),
                onTap: () => Navigator.of(sheetContext).pop(_ImportShape.text),
              ),
            ],
          ),
        ),
      );

  /// Imports one picture from the system picker onto the page.
  ///
  /// The image lands below existing content at its intrinsic aspect ratio,
  /// fitted to the typed column's width, and arrives SELECTED so the
  /// move/resize affordances teach themselves.
  Future<void> _importImage() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final PickedImage? picked;
    try {
      picked = await ImageFilePicker().pick();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not import the image: $e')),
      );
      return;
    }
    if (picked == null || !mounted) return;
    final double aspect = picked.width / picked.height;
    final double width =
        math.min(picked.width.toDouble(), _pageColumnWidth / 2);
    final double height = width / aspect;
    final NotebookImageBlock block = NotebookImageBlock(
      id: _uuid.v4(),
      data: base64Encode(picked.bytes),
      mime: picked.mime,
      x: _pagePadding + 4,
      y: _contentBottom() + _importSpacing,
      width: width,
      height: height,
    );
    setState(() {
      _blocks = <NotebookBlock>[..._blocks, block];
      _selectedImageId = block.id;
      _dirty = true;
    });
  }

  /// Moves the selected image by one drag step, in canonical page space.
  void _moveImage(String id, Offset delta) {
    setState(() {
      _blocks = <NotebookBlock>[
        for (final NotebookBlock block in _blocks)
          if (block is NotebookImageBlock && block.id == id)
            block.copyWith(
              x: math.max(0, block.x + delta.dx),
              y: math.max(0, block.y + delta.dy),
            )
          else
            block,
      ];
      _dirty = true;
    });
  }

  /// Replaces the image's geometry wholesale (resize-tab drags).
  void _resizeImage(String id, Rect geometry) {
    setState(() {
      _blocks = <NotebookBlock>[
        for (final NotebookBlock block in _blocks)
          if (block is NotebookImageBlock && block.id == id)
            block.copyWith(
              x: math.max(0, geometry.left),
              y: math.max(0, geometry.top),
              width: geometry.width,
              height: geometry.height,
            )
          else
            block,
      ];
      _dirty = true;
    });
  }

  /// The lowest edge of everything currently on the page: placed blocks
  /// (plus a nominal footprint height), flow-laid blocks at their computed
  /// slots, and every ink point.
  double _contentBottom() {
    double lowest = 0;
    double flowY = _pagePadding;
    for (final NotebookBlock block in _blocks) {
      switch (block) {
        case NotebookTextBlock t:
          lowest = math.max(lowest, (t.y ?? flowY) + _importBlockHeight);
          if (t.y == null) flowY += _unplacedBlockSpacing;
        case NotebookCheckboxBlock c:
          lowest = math.max(lowest, (c.y ?? flowY) + _importBlockHeight);
          if (c.y == null) flowY += _unplacedBlockSpacing;
        case NotebookDumpCardBlock d:
          lowest = math.max(lowest, d.y + _importBlockHeight);
        case NotebookImageBlock i:
          lowest = math.max(lowest, i.y + i.height);
        case NotebookBlock():
          break;
      }
    }
    for (final InkStroke stroke in _strokes) {
      for (final InkPoint point in stroke.points) {
        lowest = math.max(lowest, point.y);
      }
    }
    return lowest;
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
      ruling: _ruling,
      lastPenStyle: _penStyle,
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

  /// Back-button path: persist the unsaved edits, then leave. A save that
  /// fails keeps the screen open (the _save snackbar already reported it) so
  /// nothing is lost silently.
  Future<void> _saveAndPop() async {
    await _save();
    if (mounted && !_dirty) Navigator.of(context).pop();
  }

  // -------------------------------------------------------------------
  // Rendering
  // -------------------------------------------------------------------

  /// Lays out every typed block on the page, positioned where the user left
  /// it.
  ///
  /// Blocks written before they were movable have no x/y. Those are stacked
  /// in order down the page, so an old notebook opens looking the same.
  List<Widget> _buildPositionedBlocks(double viewportWidth) {
    final List<Widget> out = <Widget>[];
    double flowY = _pagePadding;
    for (final NotebookBlock block in _blocks) {
      final double? bx = switch (block) {
        NotebookTextBlock t => t.x,
        NotebookCheckboxBlock c => c.x,
        NotebookBlock() => null,
      };
      final double? by = switch (block) {
        NotebookTextBlock t => t.y,
        NotebookCheckboxBlock c => c.y,
        NotebookBlock() => null,
      };
      if (block is! NotebookTextBlock && block is! NotebookCheckboxBlock) {
        continue;
      }
      final double left = bx ?? _pagePadding;
      final double top = by ?? flowY;
      if (by == null) flowY += _unplacedBlockSpacing;

      out.add(
        Positioned(
          key: ValueKey<String>('notebook-block-${block.id}'),
          left: left,
          top: top,
          child: SizedBox(
            // The lasso measures this box's RenderBox: it is the row the
            // user sees (grip + content + remove), laid out in canonical px.
            key: _measureKeyFor(block.id),
            // Never wider than what is left of the page from this block's
            // left edge. A fixed 720 ran the row (and its X) straight off a
            // phone screen, which is why blocks could not be deleted.
            width: math.max(
              _minBlockWidth,
              math.min(_pageColumnWidth, viewportWidth - left - _pagePadding),
            ),
            child: _MovableBlock(
              id: block.id,
              // Dragging is off while the pen is down: in draw mode the whole
              // page belongs to the ink layer.
              draggable: !_drawing,
              onMoved: (Offset delta) => _onBlockMoved(block.id, delta),
              onRemove: () => _removeBlock(block.id),
              onDragActive: (bool dragging) {
                if (_draggingCard == dragging) return;
                setState(() => _draggingCard = dragging);
              },
              child: switch (block) {
                NotebookTextBlock t => _BackspaceDeletes(
                    controller: _controllerFor(t.id, t.text),
                    onDeleteLine: () => _removeBlock(t.id),
                    child: TextField(
                      key: ValueKey<String>('notebook-text-block-${t.id}'),
                      controller: _controllerFor(t.id, t.text),
                      maxLines: null,
                      style: _pageTextStyle,
                      cursorColor: NotebookInkCanvas.inkColor,
                      decoration: _pageInput('Write something…'),
                    ),
                  ),
                NotebookCheckboxBlock c => Row(
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
                        child: _BackspaceDeletes(
                          controller: _controllerFor(c.id, c.text),
                          onDeleteLine: () => _removeBlock(c.id),
                          onSplitLine: () => _splitCheckboxBlock(c),
                          child: TextField(
                            key: ValueKey<String>(
                              'notebook-checkbox-block-${c.id}',
                            ),
                            controller: _controllerFor(c.id, c.text),
                            focusNode: _focusFor(c.id),
                            maxLines: null,
                            // Android IGNORES the IME action whenever the
                            // input type carries the multi-line flag: it shows
                            // a newline key, commits the newline straight into
                            // the value, and never calls performAction. That
                            // is why intercepting KeyDownEvent alone fixed
                            // only a physical keyboard while the on-screen one
                            // still grew the box. The single-line type still
                            // WRAPS — that is maxLines' job — but its enter
                            // key now delivers an action we can act on.
                            keyboardType: TextInputType.text,
                            textInputAction: TextInputAction.next,
                            // Suppresses the default 'next' focus traversal.
                            // This list owns where the caret goes; letting the
                            // framework jump to an arbitrary neighbour first
                            // scrolls the page before the new item exists.
                            onEditingComplete: () =>
                                _controllerFor(c.id, c.text).clearComposing(),
                            onSubmitted: (_) => _splitCheckboxBlock(c),
                            style: _pageTextStyle,
                            cursorColor: NotebookInkCanvas.inkColor,
                            decoration: _pageInput('List item…'),
                          ),
                        ),
                      ),
                    ],
                  ),
                NotebookBlock() => const SizedBox.shrink(),
              },
            ),
          ),
        ),
      );
    }
    return out;
  }

  // -------------------------------------------------------------------
  // Lasso over blocks
  // -------------------------------------------------------------------

  /// Where each block anchors in canonical page space, or null for a block
  /// that has no position of its own yet (flow-laid text).
  Offset? _blockAnchor(NotebookBlock block) => switch (block) {
        NotebookTextBlock t =>
          t.x == null && t.y == null ? null : Offset(t.x ?? 0, t.y ?? 0),
        NotebookCheckboxBlock c =>
          c.x == null && c.y == null ? null : Offset(c.x ?? 0, c.y ?? 0),
        NotebookDumpCardBlock d => Offset(d.x, d.y),
        NotebookImageBlock i => Offset(i.x, i.y),
        NotebookBlock() => null,
      };

  /// The lasso footprint of [block]: measured for text/checkbox rows, model
  /// size for images, nominal 300x90 otherwise. See [lassoBlockFootprint].
  Size _blockFootprint(NotebookBlock block) =>
      lassoBlockFootprint(block, _blockMeasureKeys[block.id]);

  /// Blocks the loop caught. A block counts as circled when more than 40%
  /// of its footprint area lies inside the loop (sampled on a grid) — a
  /// hand that hooks half a card meant to grab it, while a loop that only
  /// clips a corner did not. Threshold set by Jeff on hardware.
  List<String> _blocksInLoop(List<Offset> loop) {
    final List<String> caught = <String>[];
    for (final NotebookBlock block in _blocks) {
      final Offset? anchor = _blockAnchor(block);
      if (anchor == null) continue;
      final Size footprint = _blockFootprint(block);
      // 6x4 grid = 24 samples across the footprint; > 40% inside selects.
      int inside = 0;
      const int cols = 6, rows = 4;
      for (int cx = 0; cx < cols; cx++) {
        for (int cy = 0; cy < rows; cy++) {
          final Offset sample = anchor +
              Offset(
                footprint.width * (cx + 0.5) / cols,
                footprint.height * (cy + 0.5) / rows,
              );
          if (NotebookInkCanvasState.pointInLoop(sample, loop)) inside++;
        }
      }
      if (inside > cols * rows * 0.4) caught.add(block.id);
    }
    return caught;
  }

  /// The canvas asks whether a lasso drag begins on a selected block.
  bool _lassoHitsBlock(Offset position) {
    for (final NotebookBlock block in _blocks) {
      if (!_lassoBlockIds.contains(block.id)) continue;
      final Offset? anchor = _blockAnchor(block);
      if (anchor == null) continue;
      final Size footprint = _blockFootprint(block);
      if ((anchor & footprint).inflate(16).contains(position)) return true;
    }
    return false;
  }

  /// Applies one selection-drag step to every selected block, mirroring the
  /// translation the canvas applies to the selected ink.
  void _lassoDragBlocks(Offset step) {
    if (_lassoBlockIds.isEmpty) return;
    setState(() {
      _blocks = <NotebookBlock>[
        for (final NotebookBlock block in _blocks)
          if (!_lassoBlockIds.contains(block.id))
            block
          else
            switch (block) {
              NotebookTextBlock t => t.copyWith(
                  x: (t.x ?? _pagePadding) + step.dx,
                  y: (t.y ?? _flowTopOf(t.id)) + step.dy,
                ),
              NotebookCheckboxBlock c => c.copyWith(
                  x: (c.x ?? _pagePadding) + step.dx,
                  y: (c.y ?? _flowTopOf(c.id)) + step.dy,
                ),
              NotebookDumpCardBlock d =>
                d.copyWith(x: d.x + step.dx, y: d.y + step.dy),
              NotebookImageBlock i =>
                i.copyWith(x: i.x + step.dx, y: i.y + step.dy),
              NotebookBlock() => block,
            },
      ];
      _dirty = true;
    });
  }

  /// Ensures draw mode is on before a tool tap takes effect.
  ///
  /// Every toolbar tool is live at any time (Jeff's contract): tapping the
  /// eraser, nib, or lasso outside draw mode ENTERS draw mode with that
  /// tool, instead of the icons sitting dead until Draw is pressed first.
  /// Call inside setState. No-op when already drawing, so a tap in draw
  /// mode keeps its plain toggle meaning.
  void _enterDrawMode() {
    if (_drawing) return;
    _drawing = true;
    // Same as the Draw toggle: the page belongs to the pen now, and image
    // tabs left under ink would swallow stroke starts.
    _selectedImageId = null;
  }

  /// Opens a tool's palette and applies the choice. A dismissed sheet
  /// returns null and must leave the current colour alone.
  Future<void> _pickInk(InkTool tool, Offset globalPosition) async {
    final InkColor current =
        tool == InkTool.highlighter ? _highlighterColour : _penColour;
    final InkColor? picked = await showInkPalette(
      context: context,
      tool: tool,
      selected: current,
      globalPosition: globalPosition,
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (tool == InkTool.highlighter) {
        _highlighterColour = picked;
      } else {
        _penColour = picked;
      }
      // Picking a colour selects that tool: the user just said what they
      // want to draw with.
      _enterDrawMode();
      _tool = tool;
    });
  }

  /// Deletes the lasso's catch: selected ink through the canvas, selected
  /// blocks here. Either half may be empty.
  void _deleteLassoSelection() {
    // Captured FIRST: the canvas's deleteSelection reports the selection
    // dead via onSelectionChanged, which clears _lassoBlockIds.
    final List<String> blockIds = List<String>.of(_lassoBlockIds);
    _canvasKey.currentState?.deleteSelection();
    for (final String id in blockIds) {
      _removeBlock(id);
    }
    _lassoBlockIds.clear();
    _canvasKey.currentState?.clearSelection();
  }

  /// Moves a typed block by [delta], resolving its first position from where
  /// it was actually laid out so an unplaced block does not jump.
  void _onBlockMoved(String id, Offset delta) {
    setState(() {
      _blocks = <NotebookBlock>[
        for (final NotebookBlock block in _blocks)
          if (block.id != id)
            block
          else
            switch (block) {
              NotebookTextBlock t => t.copyWith(
                  x: (t.x ?? _pagePadding) + delta.dx,
                  y: (t.y ?? _flowTopOf(id)) + delta.dy,
                ),
              NotebookCheckboxBlock c => c.copyWith(
                  x: (c.x ?? _pagePadding) + delta.dx,
                  y: (c.y ?? _flowTopOf(id)) + delta.dy,
                ),
              NotebookBlock() => block,
            },
      ];
      _dirty = true;
    });
  }

  /// Where an unplaced block currently sits in the top-down flow.
  double _flowTopOf(String id) {
    double flowY = _pagePadding;
    for (final NotebookBlock block in _blocks) {
      final double? y = switch (block) {
        NotebookTextBlock t => t.y,
        NotebookCheckboxBlock c => c.y,
        NotebookBlock() => null,
      };
      if (block is! NotebookTextBlock && block is! NotebookCheckboxBlock) {
        continue;
      }
      if (block.id == id) return y ?? flowY;
      if (y == null) flowY += _unplacedBlockSpacing;
    }
    return _pagePadding;
  }

  /// How far right the actual content reaches, in canonical page px.
  ///
  /// The width analogue of [_pageHeight]. [_pageColumnWidth] is the TYPED
  /// COLUMN's width — handwriting and images deliberately use the full area,
  /// so a page authored on a wide screen routinely holds content beyond it.
  /// Scaling a narrow viewport against the column width alone therefore
  /// clipped every stroke past x=720: on the Fold's 475dp cover screen a
  /// Journal page whose ink reached x=808 lost the right-hand end of every
  /// line ("entry int…", "of softw…"), while the 932dp inner screen was fine.
  ///
  /// Every content kind that can sit right of the column is counted:
  ///
  /// - ink, per point;
  /// - images, which carry their own `width` at their own `x`;
  /// - dump cards, which have an `x` but no width, so they get the same
  ///   [_minBlockWidth] floor their row is laid out with;
  /// - positioned text and checkbox rows. These look self-limiting —
  ///   `_buildPositionedBlocks` clamps a row to what is LEFT of the page from
  ///   its own left edge — but that clamp is floored at [_minBlockWidth] so
  ///   the drag grip and remove X stay reachable, and the floor BEATS the
  ///   clamp: a block at x=700 is laid out 700..860 however narrow the page
  ///   is. Leaving them out cut the X off exactly the rows a user had dragged
  ///   right, which is the bug that made blocks undeletable on a phone.
  ///
  /// Returns 0 for an empty page so the scale maths falls back to the column
  /// width unchanged.
  double _contentRightEdge() {
    double rightmost = 0;
    for (final InkStroke stroke in _strokes) {
      for (final InkPoint point in stroke.points) {
        rightmost = math.max(rightmost, point.x);
      }
    }
    for (final NotebookBlock block in _blocks) {
      switch (block) {
        case NotebookImageBlock i:
          rightmost = math.max(rightmost, i.x + i.width);
        case NotebookDumpCardBlock d:
          rightmost = math.max(rightmost, d.x + _minBlockWidth);
        case NotebookTextBlock t:
          if (t.x != null) {
            rightmost = math.max(rightmost, t.x! + _minBlockWidth);
          }
        case NotebookCheckboxBlock c:
          if (c.x != null) {
            rightmost = math.max(rightmost, c.x! + _minBlockWidth);
          }
        case NotebookBlock():
          break;
      }
    }
    if (rightmost == 0) return 0;
    return rightmost + _pagePadding;
  }

  /// Height of the page: always a screen beyond the lowest thing on it, so
  /// there is fresh page to write on however far down you scroll.
  double _pageHeight(double viewportHeight) {
    double lowest = 0;
    double flowY = _pagePadding;
    for (final NotebookBlock block in _blocks) {
      switch (block) {
        case NotebookTextBlock t:
          lowest = math.max(lowest, t.y ?? flowY);
          if (t.y == null) flowY += _unplacedBlockSpacing;
        case NotebookCheckboxBlock c:
          lowest = math.max(lowest, c.y ?? flowY);
          if (c.y == null) flowY += _unplacedBlockSpacing;
        case NotebookDumpCardBlock d:
          lowest = math.max(lowest, d.y);
        case NotebookBlock():
          break;
      }
    }
    for (final InkStroke stroke in _strokes) {
      for (final InkPoint point in stroke.points) {
        lowest = math.max(lowest, point.y);
      }
    }
    return math.max(viewportHeight, lowest + viewportHeight);
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
    final List<Dump> dumps = rows.map(dumpFromRow).toList(growable: false);

    return PopScope(
      canPop: !_dirty && !_saving,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop || _saving) return;
        // Back means "I'm done", not "throw it away": unsaved edits are
        // saved on the way out. Only a FAILED save keeps the screen open,
        // with the failure snackbar explaining why.
        unawaited(_saveAndPop());
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
            // The search icon exists ONLY while handwriting search is on
            // (the provider is the gate — no capability call from here).
            // It joins the row without displacing any existing tool.
            if (ref.watch(handwritingSearchEnabledProvider))
              IconButton(
                key: const ValueKey<String>('notebook-editor-search'),
                icon: const Icon(Icons.search),
                tooltip: 'Find in notebook',
                onPressed: _notebook == null ? null : _openFind,
              ),
            IconButton(
              icon: const Icon(Icons.save),
              tooltip: 'Save notebook',
              onPressed: _notebook == null || _saving ? null : _save,
            ),
          ],
          // ONE unified toolbar, always present: draw toggle, eraser,
          // nib, lasso, undo, redo and the pen size all live on this row.
          // Outside draw mode the drawing tools are DISABLED, not hidden —
          // a row that never reshuffles is one the hand can learn (user
          // call: "one unified menu bar at the top").
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(56),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 12, 4),
              child: Row(
                children: <Widget>[
                  // The IconButton's own tooltip would install a long-press
                  // recognizer DEEPER than this detector (Tooltip's default
                  // triggerMode is longPress on touch), win the arena, and
                  // swallow the palette gesture — so the tooltip is manual
                  // here. Mouse hover is unaffected by triggerMode.
                  Tooltip(
                    message: _drawing ? 'Stop drawing' : 'Draw',
                    triggerMode: TooltipTriggerMode.manual,
                    child: GestureDetector(
                      onLongPressStart: _notebook == null
                          ? null
                          : (LongPressStartDetails d) => _pickInk(
                                InkTool.pen,
                                d.globalPosition,
                              ),
                      child: IconButton(
                        icon: const Icon(Icons.draw),
                        visualDensity: VisualDensity.compact,
                        isSelected: _drawing && _tool == InkTool.pen,
                        color: Color(_penColour.argb),
                        onPressed: _notebook == null
                            ? null
                            : () => setState(() {
                                  if (_drawing && _tool == InkTool.pen) {
                                    // Leaving draw mode: the pen is the safe
                                    // default whenever drawing resumes — a
                                    // stranded eraser would delete work, a
                                    // stranded highlighter would wash the next
                                    // handwriting stroke in colour.
                                    _drawing = false;
                                    _erasing = false;
                                    _lassoing = false;
                                    _lassoSelection = false;
                                    _tool = InkTool.pen;
                                    return;
                                  }
                                  _enterDrawMode();
                                  _tool = InkTool.pen;
                                }),
                      ),
                    ),
                  ),
                  Tooltip(
                    message: 'Highlighter. Long-press for colours',
                    triggerMode: TooltipTriggerMode.manual,
                    child: GestureDetector(
                      onLongPressStart: _notebook == null
                          ? null
                          : (LongPressStartDetails d) => _pickInk(
                                InkTool.highlighter,
                                d.globalPosition,
                              ),
                      child: IconButton(
                        key: const ValueKey('notebook-highlighter'),
                        icon: const Icon(Icons.border_color),
                        visualDensity: VisualDensity.compact,
                        isSelected: _drawing && _tool == InkTool.highlighter,
                        color: Color(_highlighterColour.argb),
                        onPressed: _notebook == null
                            ? null
                            : () => setState(() {
                                  _enterDrawMode();
                                  _tool = InkTool.highlighter;
                                  // Mutually exclusive gestures, same rule the
                                  // eraser and lasso already follow.
                                  _erasing = false;
                                  _lassoing = false;
                                  _lassoSelection = false;
                                }),
                      ),
                    ),
                  ),
                  IconButton(
                    // An unlabelled mode is how you end up erasing when you
                    // meant to draw, so the active tool is always shown as
                    // selected.
                    icon: Icon(
                      _erasing ? Icons.edit : Icons.auto_fix_normal,
                    ),
                    tooltip: _erasing ? 'Switch to pen' : 'Erase lines',
                    visualDensity: VisualDensity.compact,
                    isSelected: _erasing,
                    // Every tool is live at any time (Jeff's contract): a
                    // tap outside draw mode ENTERS draw mode with this tool
                    // instead of being dead until Draw is pressed first.
                    onPressed: _notebook == null
                        ? null
                        : () => setState(() {
                              _enterDrawMode();
                              _erasing = !_erasing;
                              if (_erasing) _lassoing = false;
                            }),
                  ),
                  IconButton(
                    key: const ValueKey('notebook-pen-style'),
                    // The nib: fountain tapers with pen pressure like
                    // Samsung Notes; ballpoint is the original uniform
                    // stroke.
                    icon: Icon(
                      _penStyle == PenStyle.fountain
                          ? Icons.brush
                          : Icons.mode_edit_outline,
                    ),
                    tooltip: _penStyle == PenStyle.fountain
                        ? 'Fountain pen (pressure). Tap for ballpoint'
                        : 'Ballpoint. Tap for fountain pen (pressure)',
                    visualDensity: VisualDensity.compact,
                    isSelected: _penStyle == PenStyle.fountain,
                    onPressed: _notebook == null
                        ? null
                        : () => setState(() {
                              _enterDrawMode();
                              _penStyle = _penStyle == PenStyle.fountain
                                  ? PenStyle.ballpoint
                                  : PenStyle.fountain;
                              // A nib switch is a change: it must survive
                              // reopen, so the next save persists it.
                              _dirty = true;
                            }),
                  ),
                  IconButton(
                    key: const ValueKey('notebook-lasso'),
                    // The smart lasso: circle ink to select it, drag the
                    // selection anywhere, delete it from this row.
                    icon: const Icon(Icons.gesture),
                    tooltip: _lassoing ? 'Exit lasso' : 'Lasso select',
                    visualDensity: VisualDensity.compact,
                    isSelected: _lassoing,
                    onPressed: _notebook == null
                        ? null
                        : () => setState(() {
                              _enterDrawMode();
                              _lassoing = !_lassoing;
                              // Lasso and eraser are exclusive: a gesture
                              // can select or erase, never both.
                              if (_lassoing) _erasing = false;
                              if (!_lassoing) _lassoSelection = false;
                            }),
                  ),
                  if (_lassoing)
                    IconButton(
                      key: const ValueKey('notebook-lasso-delete'),
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Delete selection',
                      visualDensity: VisualDensity.compact,
                      // Enabled only while something is circled — a dead
                      // delete button reads as broken, a live one with
                      // nothing selected would surprise.
                      onPressed: _lassoSelection ? _deleteLassoSelection : null,
                    ),
                  IconButton(
                    icon: const Icon(Icons.undo),
                    tooltip: 'Undo stroke',
                    visualDensity: VisualDensity.compact,
                    // Undo/redo act on ink history and are safe any time;
                    // they do not flip modes.
                    onPressed: _notebook == null
                        ? null
                        : () => _canvasKey.currentState?.undoLastStroke(),
                  ),
                  IconButton(
                    key: const ValueKey<String>('notebook-redo'),
                    icon: const Icon(Icons.redo),
                    tooltip: 'Redo',
                    visualDensity: VisualDensity.compact,
                    onPressed: _notebook == null
                        ? null
                        : () => _canvasKey.currentState?.redo(),
                  ),
                  Expanded(
                    child: PenSizeControl(
                      value: _penWidth,
                      onChanged: _notebook == null
                          ? null
                          : (double width) => setState(() => _penWidth = width),
                    ),
                  ),
                ],
              ),
            ),
          ),
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
                          case _InsertAction.image:
                            unawaited(_importImage());
                          case _InsertAction.cycleRuling:
                            _cycleRuling();
                          case _InsertAction.recentre:
                            _pageScroll.jumpTo(0);
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
                        const PopupMenuItem<_InsertAction>(
                          key: ValueKey('notebook-insert-image'),
                          value: _InsertAction.image,
                          child: ListTile(
                            leading: Icon(Icons.image_outlined),
                            title: Text('Image'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuDivider(),
                        // Cycles blank -> small -> medium -> blank. A submenu
                        // would be three taps deep for a setting most people
                        // choose once; the label always states where the next
                        // tap lands.
                        PopupMenuItem<_InsertAction>(
                          key: const ValueKey('notebook-ruling-item'),
                          value: _InsertAction.cycleRuling,
                          child: ListTile(
                            leading: const Icon(Icons.format_align_justify),
                            title: Text('Page: ${_ruling.label}'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuDivider(),
                        // The page can be panned until the work is off-screen
                        // on identical black canvas; this is the way home.
                        const PopupMenuItem<_InsertAction>(
                          value: _InsertAction.recentre,
                          child: ListTile(
                            leading: Icon(Icons.filter_center_focus),
                            title: Text('Back to start'),
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
        body: Column(
          children: <Widget>[
            // The find bar rides above the page, Ctrl+F style. Mounted only
            // while open, so the ordinary editor pays nothing for it.
            if (_findOpen)
              NotebookFindBar(
                controller: _findQuery,
                matchCount: _findMatches.length,
                currentIndex: _findIndex,
                onQueryChanged: (String query) => unawaited(_runFind(query)),
                onPrev: () => _findStep(-1),
                onNext: () => _findStep(1),
                onClose: _closeFind,
              ),
            Expanded(child: _buildBody(rowsById)),
          ],
        ),
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

    // An endless vertical roll, like Samsung Notes.
    //
    // This replaces a pinch/pan InteractiveViewer: on device its pan
    // recognizer competed with the pen for every drag, so writing and erasing
    // fought the page. With one axis and no zoom there is nothing left to
    // compete -- and while drawing, the scroll is locked outright.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // Scale-to-fit: block x/y and ink points persist in a CANONICAL page
        // space at least [_pageColumnWidth] wide. A narrower viewport renders
        // the whole page scaled by viewport/canon, so a layout authored on a
        // tablet arrives on a phone proportionally smaller instead of hanging
        // off the right edge ("saved a bit of a notebook on the tab s10 ...
        // way off to the side on my phone"). Wider viewports keep scale 1.
        //
        // The denominator is the widest of the typed column and the page's
        // ACTUAL content: handwriting and cards use the full area, not just
        // the column, so a page whose ink reaches x=808 must scale against
        // 808 (+padding) or everything past the column is clipped away. That
        // was the Fold's cover screen losing the right end of every line.
        final double canon =
            math.max(_pageColumnWidth, _contentRightEdge());
        final double scale = math.min(1.0, constraints.maxWidth / canon);
        // Captured for scroll-to-match: a match bbox is canonical, the
        // scroll offset is in viewport px. Plain assignment — layout is not
        // a place to setState, and nothing rebuilds off this value.
        _pageScale = scale;
        final double canonicalWidth = constraints.maxWidth / scale;
        final double pageHeight = _pageHeight(constraints.maxHeight / scale);
        return SingleChildScrollView(
          key: const ValueKey('notebook-canvas-scroll'),
          controller: _pageScroll,
          physics: _drawing || _draggingCard || _stylusActive
              ? const NeverScrollableScrollPhysics()
              : const ClampingScrollPhysics(),
          child: SizedBox(
            key: const ValueKey('notebook-canvas-surface'),
            height: pageHeight * scale,
            width: constraints.maxWidth,
            // FittedBox scales both painting AND hit-testing, so pointer
            // positions inside arrive already in canonical coordinates and
            // ink strokes persist canonically with no per-point conversion.
            child: FittedBox(
              fit: BoxFit.fill,
              alignment: Alignment.topLeft,
              child: SizedBox(
                height: pageHeight,
                width: canonicalWidth,
                child: Stack(
                  children: <Widget>[
                    // Bottom: the page itself -- black, per the ink contract.
                    // Tapping bare page deselects any selected image.
                    Positioned.fill(
                      child: GestureDetector(
                        key: const ValueKey('notebook-page-background'),
                        behavior: HitTestBehavior.opaque,
                        onTap: _selectedImageId == null
                            ? null
                            : () => setState(() => _selectedImageId = null),
                        child: const ColoredBox(
                          color: NotebookInkCanvas.backgroundColor,
                        ),
                      ),
                    ),
                    // Rule lines, directly above the page colour and beneath every
                    // piece of content. This fills the whole scrollable surface,
                    // not the viewport, so the ruling extends with the page as it
                    // grows and stays put while scrolling rather than sliding
                    // against the writing.
                    Positioned.fill(
                      child: IgnorePointer(
                        child: RepaintBoundary(
                          child: CustomPaint(
                            key: const ValueKey('notebook-ruling'),
                            painter: NotebookRulingPainter(ruling: _ruling),
                          ),
                        ),
                      ),
                    ),
                    // Typed blocks, each positioned where it was left. Laid out
                    // in canonical space; the FittedBox above scales them.
                    ..._buildPositionedBlocks(canonicalWidth),
                    // Imported images float like cards. Positioned children
                    // must be direct children of this Stack. They sit above
                    // typed blocks (imported later = laid on top, like a
                    // photo dropped onto a desk) and below the ink layer so
                    // handwriting annotates them.
                    for (final NotebookBlock block in _blocks)
                      if (block is NotebookImageBlock)
                        Positioned(
                          key: ValueKey<String>(
                            'notebook-image-pos-${block.id}',
                          ),
                          // The selected widget grows by the chrome inset on
                          // every side (tabs must sit INSIDE its hit-test
                          // bounds); offsetting here keeps the image pixels
                          // at (x, y) in both states.
                          left: _selectedImageId == block.id
                              ? block.x - kNotebookImageChromeInset
                              : block.x,
                          top: _selectedImageId == block.id
                              ? block.y - kNotebookImageChromeInset
                              : block.y,
                          child: NotebookImageBlockWidget(
                            block: block,
                            selected: _selectedImageId == block.id,
                            interactive: !_drawing,
                            onSelect: () => setState(
                              () => _selectedImageId = block.id,
                            ),
                            onMoved: (Offset delta) =>
                                _moveImage(block.id, delta),
                            onResized: (Rect geometry) =>
                                _resizeImage(block.id, geometry),
                            onCommit: () {},
                            onRemove: () {
                              setState(() => _selectedImageId = null);
                              _removeBlock(block.id);
                            },
                            onDragActive: (bool dragging) {
                              if (_draggingCard == dragging) return;
                              setState(() => _draggingCard = dragging);
                            },
                          ),
                        ),
                    // Floating recording cards. Each is a Positioned, so they
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
                    // Top: the ink layer. It ignores pointers unless draw mode is
                    // on, so typing and card dragging work normally otherwise.
                    Positioned.fill(
                      child: RepaintBoundary(
                        child: NotebookInkCanvas(
                          key: _canvasKey,
                          strokes: _strokes,
                          drawingEnabled: _drawing,
                          erasing: _erasing,
                          lassoing: _lassoing,
                          onSelectionChanged: (bool has) {
                            if (_lassoSelection == has) return;
                            setState(() {
                              _lassoSelection = has;
                              // The canvas dropping its selection (mode exit,
                              // empty loop) drops the block half too — they are
                              // one selection to the user.
                              if (!has) _lassoBlockIds.clear();
                            });
                          },
                          onLassoLoop: (List<Offset> loop) {
                            _lassoBlockIds
                              ..clear()
                              ..addAll(_blocksInLoop(loop));
                            return _lassoBlockIds.length;
                          },
                          hitsExternalSelection: _lassoHitsBlock,
                          onSelectionDragStep: _lassoDragBlocks,
                          penWidth: _penWidth,
                          penStyle: _penStyle,
                          tool: _tool,
                          colour: _activeColour,
                          // Palm rejection, page half: while the pen is present
                          // the scroll physics lock so a resting hand cannot
                          // shove the page mid-word. The canvas half (touch not
                          // inking) lives inside the widget itself.
                          onStylusPresence: (bool present) {
                            if (_stylusActive == present) return;
                            setState(() => _stylusActive = present);
                          },
                          // The page below already painted the backdrop, so the
                          // ink layer composites directly instead of painting
                          // black and filtering it back out.
                          opaqueBackground: false,
                          // Find-in-notebook: all matches banded, the current
                          // one stronger. Both empty while no find is open.
                          highlightedStrokeIds: _findHighlightIds,
                          currentMatchStrokeIds: _findCurrentIds,
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
            ),
          ),
        );
      },
    );
  }
}

/// A typed block that can be dragged around the page by a grip handle.
///
/// The grip is separate from the content on purpose: dragging anywhere on a
/// text field would fight placing the text cursor, so the handle moves the
/// block and the field still edits normally.
/// Deletes the whole line when backspace is pressed on an empty one.
///
/// Jeff: "when you tap backspace when there's nothing left in the line ...
/// it deletes the line item that you are currently on."
///
/// The key event is intercepted ABOVE the field: a TextField with an empty
/// value swallows backspace itself and reports nothing, so there is no
/// callback to hang this off.
/// Keyboard behaviour for a list line: backspace deletes an empty one, and
/// (for checkbox items) enter starts the next one.
class _BackspaceDeletes extends StatelessWidget {
  const _BackspaceDeletes({
    required this.controller,
    required this.onDeleteLine,
    required this.child,
    this.onSplitLine,
  });

  final TextEditingController controller;
  final VoidCallback onDeleteLine;

  /// Non-null only for checkbox items. A plain text block leaves this null so
  /// enter keeps inserting newlines — a paragraph is meant to be multi-line.
  final VoidCallback? onSplitLine;
  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
        onKeyEvent: (FocusNode node, KeyEvent event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;

          if (event.logicalKey == LogicalKeyboardKey.enter) {
            final VoidCallback? split = onSplitLine;
            if (split == null) return KeyEventResult.ignored;
            // Handled BEFORE the field sees it, so no newline is inserted and
            // the box never grows.
            split();
            return KeyEventResult.handled;
          }

          if (event.logicalKey != LogicalKeyboardKey.backspace) {
            return KeyEventResult.ignored;
          }
          // Only when the line is genuinely empty: otherwise backspace must
          // keep deleting characters normally.
          if (controller.text.isNotEmpty) return KeyEventResult.ignored;
          onDeleteLine();
          return KeyEventResult.handled;
        },
        child: child,
      );
}

/// Pan recognizer for a block's grip handle.
///
/// The page scroll also wants vertical drags; in a normal arena it wins and
/// the grip does nothing. A drag that starts on the grip is unambiguous, so
/// claim it the moment the finger moves.
class _GripPanRecognizer extends PanGestureRecognizer {
  _GripPanRecognizer({super.debugOwner, this.onSlopCrossed});

  /// Fires once the finger has genuinely travelled past the touch slop.
  ///
  /// The page is held still from here rather than from onPointerDown: holding
  /// it on contact empties the gesture arena, and an uncontested
  /// PanGestureRecognizer accepts on the very first move -- which with
  /// DragStartBehavior.down replays the 1-2px wobble of an ordinary tap and
  /// nudges the block. Holding only after slop keeps taps inert AND keeps the
  /// page from stealing the drag, because everything after slop is delivered
  /// to a recognizer that has already won.
  final VoidCallback? onSlopCrossed;

  final Map<int, Offset> _origins = <int, Offset>{};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _origins[event.pointer] = event.position;
    super.addAllowedPointer(event);
  }

  /// Claim distance for the grip, measured on device.
  ///
  /// Flutter's kTouchSlop is 18px, but the enclosing SingleChildScrollView
  /// claims a vertical drag at roughly half that: an instrumented run on the
  /// tablet logged travel reaching only 8.6px before this recognizer was
  /// REJECTED outright, so a threshold of 18 could never be reached. The grip
  /// is a dedicated 20px handle that means nothing except "move me", so a
  /// smaller claim costs nothing and is the only way to win the arena.
  double _gripSlop(PointerEvent event) =>
      computeHitSlop(event.kind, gestureSettings) / 4;

  @override
  void handleEvent(PointerEvent event) {
    super.handleEvent(event);
    // Past the touch slop only. Claiming every stray move swallowed taps on
    // the dump card (tapping a recording stopped opening it), and the grip
    // sits next to a text field whose cursor placement must survive a
    // slightly wobbly tap.
    if (event is PointerMoveEvent) {
      final Offset? origin = _origins[event.pointer];
      if (origin != null &&
          (event.position - origin).distance > _gripSlop(event)) {
        // Both halves are needed. Claiming early wins the arena against the
        // scroll view; holding the page still keeps it won for the rest of
        // the gesture, and is what a later drag past kTouchSlop relies on.
        onSlopCrossed?.call();
        resolve(GestureDisposition.accepted);
      }
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _origins.remove(event.pointer);
    }
  }
}

class _MovableBlock extends StatefulWidget {
  const _MovableBlock({
    required this.id,
    required this.draggable,
    required this.onMoved,
    required this.onRemove,
    required this.child,
    this.onDragActive,
  });

  final String id;
  final bool draggable;

  /// Tells the editor to hold the page still for the duration of a grip
  /// gesture, exactly as the dump card does.
  ///
  /// Without this the page scroll and the grip recognizer both compete for a
  /// slow vertical drag. The scroll accepts on the smaller threshold, wins the
  /// arena, and REJECTS the grip mid-gesture -- so the block stops following
  /// the finger and the page slides instead. Fired from onPointerDown, which
  /// precedes every arena decision: hanging it off onStart would be too late,
  /// because onStart never fires when the rival wins.
  final ValueChanged<bool>? onDragActive;

  /// Reports the block's new absolute position when the drag settles.
  final ValueChanged<Offset> onMoved;
  final VoidCallback onRemove;
  final Widget child;

  @override
  State<_MovableBlock> createState() => _MovableBlockState();
}

class _MovableBlockState extends State<_MovableBlock> {
  /// Offset accumulated during the current drag.
  ///
  /// The block tracks its own drag and reports once at the end, rather than
  /// pushing every delta up: reporting per-update rebuilds this widget from
  /// the parent mid-gesture, which drops the in-flight drag and leaves the
  /// block where it started.
  Offset _dragged = Offset.zero;

  @override
  Widget build(BuildContext context) => Transform.translate(
        offset: _dragged,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (widget.draggable)
              RawGestureDetector(
                key: ValueKey<String>('notebook-block-grip-${widget.id}'),
                behavior: HitTestBehavior.opaque,
                // The page scroll competes for vertical drags and wins them
                // in a normal arena, so a grip drag did nothing at all. This
                // recognizer claims the gesture as soon as the finger moves;
                // a drag starting on the grip is never meant to scroll.
                gestures: <Type, GestureRecognizerFactory>{
                  _GripPanRecognizer:
                      GestureRecognizerFactoryWithHandlers<_GripPanRecognizer>(
                    () => _GripPanRecognizer(
                      debugOwner: this,
                      onSlopCrossed: () => widget.onDragActive?.call(true),
                    ),
                    (_GripPanRecognizer instance) {
                      // `down` keeps the block faithful to the finger: the
                      // slop consumed before recognition is reported too.
                      instance.dragStartBehavior = DragStartBehavior.down;
                      instance.onUpdate = (DragUpdateDetails details) =>
                          setState(() => _dragged += details.delta);
                      instance.onEnd = (_) {
                        final Offset settled = _dragged;
                        setState(() => _dragged = Offset.zero);
                        widget.onDragActive?.call(false);
                        widget.onMoved(settled);
                      };
                      instance.onCancel = () {
                        setState(() => _dragged = Offset.zero);
                        widget.onDragActive?.call(false);
                      };
                    },
                  ),
                },
                child: const Padding(
                  padding: EdgeInsets.only(top: 12, right: 4),
                  child: Icon(
                    Icons.drag_indicator,
                    size: 20,
                    color: NotebookInkCanvas.inkColor,
                  ),
                ),
              ),
            Expanded(child: widget.child),
            _RemoveBlockButton(
              key: ValueKey<String>('notebook-block-remove-${widget.id}'),
              onPressed: widget.onRemove,
            ),
          ],
        ),
      );
}

class _RemoveBlockButton extends StatelessWidget {
  const _RemoveBlockButton({required this.onPressed, super.key});

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
