// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Listen mode for a transcript (docs/design/2026-09-25-tap-to-hear.md §3):
// the read-only twin of the editor. Every word is a tap target that
// seeks playback to just before it; the word under the playhead is
// highlighted and kept in view; low-confidence words are tinted so a
// second listen is one tap away.
//
// The widget is self-contained on purpose — it takes a position
// listenable and a seek callback rather than the playback controller, so
// it is testable without audio and reusable wherever a transcript and a
// player meet.
import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../services/transcript_alignment.dart';
import '../services/transcript_timings.dart';

class ListenTranscriptView extends StatefulWidget {
  const ListenTranscriptView({
    super.key,
    required this.timings,
    required this.transcript,
    required this.position,
    required this.onSeek,
    required this.audioLocal,
    required this.serverPaired,
    required this.onRetranscribe,
    this.onDownloadAudio,
    this.onSpeakerTap,
    this.highlightedWords = const <int>{},
    this.currentWord,
  });

  /// Token indexes (word mode) that a transcript search hit; painted so
  /// the hits are visible while listening. Empty when no search is active.
  final Set<int> highlightedWords;

  /// The token index of the search hit the match bar currently points at;
  /// painted stronger than [highlightedWords] and scrolled into view when
  /// it changes.
  final int? currentWord;

  /// Null when the recording has never produced timings.
  final TranscriptTimings? timings;

  /// The user's (possibly edited) transcript text.
  final String transcript;

  /// Playback position; the highlight follows it.
  final ValueListenable<Duration> position;

  /// Called with the target position when the user taps a timed word or
  /// sentence. The caller seeks and starts playback.
  final void Function(Duration target) onSeek;

  /// False when the audio is not on this device: words still render but
  /// a download affordance replaces tap-to-play.
  final bool audioLocal;

  /// Whether "Re-transcribe for word timing" can do anything.
  final bool serverPaired;
  final VoidCallback onRetranscribe;
  final VoidCallback? onDownloadAudio;

  /// Called with the raw timings label (`Speaker 1`) when the user taps a
  /// speaker header. The detail screen opens the Name-speakers sheet; null
  /// leaves the header as plain text.
  final void Function(String label)? onSpeakerTap;

  @override
  State<ListenTranscriptView> createState() => ListenTranscriptViewState();
}

class ListenTranscriptViewState extends State<ListenTranscriptView> {
  TranscriptAlignment? _alignment;
  int? _highlighted;
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _wordKeys = <int, GlobalKey>{};
  final Map<int, GlobalKey> _segmentKeys = <int, GlobalKey>{};

  /// After the user scrolls by hand, auto-scroll stays out of the way
  /// for a few seconds (spec §3.3).
  DateTime? _userScrolledAt;
  static const Duration _manualScrollGrace = Duration(seconds: 3);

  /// Exposed for tests: the token (words) or segment (sentences) index
  /// currently under the playhead.
  int? get highlightedIndex => _highlighted;

  bool get _wordMode => widget.timings?.hasWords ?? false;

  @override
  void initState() {
    super.initState();
    _rebuildAlignment();
    widget.position.addListener(_onPosition);
    _scroll.addListener(_onScroll);
    _onPosition();
  }

  @override
  void didUpdateWidget(ListenTranscriptView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (old.position != widget.position) {
      old.position.removeListener(_onPosition);
      widget.position.addListener(_onPosition);
    }
    if (old.timings != widget.timings || old.transcript != widget.transcript) {
      _rebuildAlignment();
      _onPosition();
    }
    final int? current = widget.currentWord;
    if (current != null && current != old.currentWord && _wordMode) {
      // The user stepped the match bar: that is an explicit ask, so it
      // overrides the manual-scroll grace.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _keepInView(current, force: true);
      });
    }
  }

  @override
  void dispose() {
    widget.position.removeListener(_onPosition);
    _scroll.dispose();
    super.dispose();
  }

  void _rebuildAlignment() {
    final t = widget.timings;
    _alignment =
        t != null && t.hasWords ? alignTranscript(widget.transcript, t) : null;
    _wordKeys.clear();
    _segmentKeys.clear();
  }

  void _onScroll() {
    // Only user-driven scrolls count; programmatic animateTo also fires
    // this, so the auto-scroller stamps _autoScrolling around its call.
    if (_autoScrolling) return;
    _userScrolledAt = DateTime.now();
  }

  bool _autoScrolling = false;

  void _onPosition() {
    final seconds = widget.position.value.inMilliseconds / 1000;
    final int? next;
    if (_wordMode) {
      next = _alignment?.currentTokenIndex(seconds);
    } else {
      next = widget.timings?.currentSegmentIndex(seconds);
    }
    if (next == _highlighted) return;
    setState(() => _highlighted = next);
    if (next != null) _keepInView(next);
  }

  void _keepInView(int index, {bool force = false}) {
    final since = _userScrolledAt;
    if (!force &&
        since != null &&
        DateTime.now().difference(since) < _manualScrollGrace) {
      return;
    }
    final key = _wordMode ? _wordKeys[index] : _segmentKeys[index];
    final ctx = key?.currentContext;
    if (ctx == null || !_scroll.hasClients) return;
    _autoScrolling = true;
    unawaited(
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.4, // middle third of the viewport
        duration: const Duration(milliseconds: 200),
      ).whenComplete(() => _autoScrolling = false),
    );
  }

  /// Exposed for tests.
  ConfidenceBucket bucketFor(int tokenIndex) =>
      confidenceBucket(_alignment!.tokens[tokenIndex].confidence);

  void _tap(double? startSeconds) {
    if (startSeconds == null || !widget.audioLocal) return;
    widget.onSeek(seekTargetFor(startSeconds));
  }

  @override
  Widget build(BuildContext context) {
    final timings = widget.timings;
    if (timings == null) return _untimed(context);

    final theme = Theme.of(context);
    final children = <Widget>[
      if (!widget.audioLocal && widget.onDownloadAudio != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: OutlinedButton.icon(
            onPressed: widget.onDownloadAudio,
            icon: const Icon(Icons.download),
            label: const Text('Download audio to play'),
          ),
        ),
      if (_wordMode)
        _wordFlow(context, timings)
      else
        _sentenceFlow(context, timings),
      if (_wordMode && (_alignment?.hasInsertions ?? false))
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Timings follow your edits where words match; added words '
            'have no moment to play.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      if (!_wordMode && widget.serverPaired)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: TextButton.icon(
            onPressed: widget.onRetranscribe,
            icon: const Icon(Icons.replay),
            label: const Text('Re-transcribe for word timing'),
          ),
        ),
    ];
    return SingleChildScrollView(
      controller: _scroll,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _untimed(BuildContext context) {
    return SingleChildScrollView(
      controller: _scroll,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText(widget.transcript),
          if (widget.serverPaired)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextButton.icon(
                onPressed: widget.onRetranscribe,
                icon: const Icon(Icons.replay),
                label: const Text('Re-transcribe for word timing'),
              ),
            ),
        ],
      ),
    );
  }

  /// Words as tappable spans, grouped by segment so speaker labels can
  /// sit at each change. Alignment tokens are matched back to segments
  /// by time: a token belongs to the last segment starting at or before
  /// its start; untimed tokens ride with the previous timed one.
  Widget _wordFlow(BuildContext context, TranscriptTimings timings) {
    final alignment = _alignment!;
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyLarge!;
    final groups = <_Group>[];
    String? lastSpeaker;
    var segIdx = 0;
    _Group? current;
    for (var i = 0; i < alignment.tokens.length; i++) {
      final tok = alignment.tokens[i];
      if (tok.start != null) {
        while (segIdx + 1 < timings.segments.length &&
            timings.segments[segIdx + 1].start <= tok.start!) {
          segIdx++;
        }
      }
      final speaker = timings.segments[segIdx].speaker;
      if (current == null || speaker != lastSpeaker) {
        current = _Group(speaker: speaker, first: i);
        groups.add(current);
        lastSpeaker = speaker;
      }
      current.last = i;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final g in groups) ...[
          if (g.speaker != null) _speakerHeader(theme, g.speaker!),
          Text.rich(
            TextSpan(
              children: [
                for (var i = g.first; i <= g.last; i++)
                  ..._wordSpans(i, alignment.tokens[i], base, theme),
              ],
            ),
          ),
        ],
      ],
    );
  }

  List<InlineSpan> _wordSpans(
    int index,
    AlignedToken tok,
    TextStyle base,
    ThemeData theme,
  ) {
    final key = _wordKeys.putIfAbsent(index, GlobalKey.new);
    final highlighted = index == _highlighted;
    final bucket = confidenceBucket(tok.confidence);
    final scheme = theme.colorScheme;
    final bool currentMatch = index == widget.currentWord;
    final bool matched = widget.highlightedWords.contains(index);
    Color? bg;
    if (highlighted) {
      bg = scheme.primaryContainer;
    } else if (currentMatch) {
      bg = scheme.tertiaryContainer;
    } else if (matched) {
      bg = scheme.tertiaryContainer.withValues(alpha: 0.5);
    } else if (tok.isTimed) {
      bg = switch (bucket) {
        ConfidenceBucket.low => scheme.errorContainer,
        ConfidenceBucket.uncertain =>
          scheme.errorContainer.withValues(alpha: 0.45),
        ConfidenceBucket.confident => null,
      };
    }
    final style = base.copyWith(
      backgroundColor: bg,
      color: tok.isTimed ? null : scheme.onSurfaceVariant,
      fontWeight: highlighted || currentMatch ? FontWeight.w600 : null,
    );
    return [
      WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: GestureDetector(
          key: ValueKey('listen-word-$index'),
          behavior: HitTestBehavior.opaque,
          onTap: tok.isTimed ? () => _tap(tok.start) : null,
          child: Text(tok.text, key: key, style: style),
        ),
      ),
      TextSpan(text: tok.trailing.isEmpty ? ' ' : tok.trailing, style: base),
    ];
  }

  /// A speaker label above its turns. Tappable (spec §4.3) so the header
  /// itself is the Listen-mode way into the Name-speakers sheet; the label
  /// stays the raw timings one after a rename (S1=b).
  Widget _speakerHeader(ThemeData theme, String label) {
    final onTap = widget.onSpeakerTap;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: InkWell(
        key: ValueKey('listen-speaker-header-$label'),
        onTap: onTap == null ? null : () => onTap(label),
        borderRadius: BorderRadius.circular(4),
        child: Text(
          label,
          style: theme.textTheme.labelLarge
              ?.copyWith(color: theme.colorScheme.primary),
        ),
      ),
    );
  }

  /// Sentence-level fallback for segment-only timings.
  Widget _sentenceFlow(BuildContext context, TranscriptTimings timings) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    String? lastSpeaker;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < timings.segments.length; i++) ...[
          if (timings.segments[i].speaker != null &&
              timings.segments[i].speaker != lastSpeaker)
            _speakerHeader(theme, lastSpeaker = timings.segments[i].speaker!),
          GestureDetector(
            key: ValueKey('listen-segment-$i'),
            behavior: HitTestBehavior.opaque,
            onTap: () => _tap(timings.segments[i].start),
            child: Container(
              key: _segmentKeys.putIfAbsent(i, GlobalKey.new),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
              decoration: BoxDecoration(
                color: i == _highlighted ? scheme.primaryContainer : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                timings.segments[i].text,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: i == _highlighted ? FontWeight.w600 : null,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _Group {
  _Group({required this.speaker, required this.first}) : last = first;
  final String? speaker;
  final int first;
  int last;
}
