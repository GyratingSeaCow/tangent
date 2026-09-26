// SPDX-License-Identifier: AGPL-3.0-or-later
/// Settings section for the server's custom vocabulary (boost words) —
/// docs/design/2026-09-26-custom-vocabulary.md §6b.
///
/// One global list, stored on the server and fed to faster-whisper's
/// `hotwords` on every transcription window (and to the summarizer as
/// preferred spellings). This editor is the only place it is written.
///
/// Mirrors the Arc-B custom-template editor in `ai_summaries_section.dart`:
/// controller + `_saved` + `_dirty` + `_busy`, an explicit Save, a Clear
/// behind a confirm, and NO autosave — a half-typed name must never reach
/// the server. The status line is computed CLIENT-side from the field text
/// with the same rules the server applies ([normalizeVocabulary]), so the
/// count moves as you type; the server's numbers replace it after Save.
///
/// Hidden entirely when this device has no saved server (unpaired): there
/// is nothing to edit until there is a server to hold the list.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/api_exception.dart';
import '../../services/vocabulary.dart';
import '../../services/whisper_model_client.dart';
import '../server/server_connection_screen.dart'
    show secureStoreProvider, transcriptionClientProvider;
import 'whisper_model_section.dart' show whisperModelClientProvider;

/// Whether this device is paired with a server (a saved server URL exists).
///
/// WATCHES [transcriptionClientProvider] so pairing or re-pairing rebuilds
/// the answer — secure storage itself is not observable. Any read failure
/// (Linux without a Secret Service, missing plugin in tests) counts as
/// unpaired: hiding an editor is the safe failure, not a crash.
final vocabularyPairedProvider = FutureProvider<bool>((ref) async {
  ref.watch(transcriptionClientProvider);
  final store = ref.watch(secureStoreProvider);
  try {
    final String? url = await store.getServerUrl();
    return url != null && url.trim().isNotEmpty;
  } catch (_) {
    return false;
  }
});

class CustomVocabularySection extends ConsumerStatefulWidget {
  const CustomVocabularySection({super.key});

  @override
  ConsumerState<CustomVocabularySection> createState() =>
      _CustomVocabularySectionState();
}

class _CustomVocabularySectionState
    extends ConsumerState<CustomVocabularySection> {
  /// The editor's text. Seeded by [_rehydrate] from the server; only
  /// [_save] and [_clear] write it back.
  final TextEditingController _controller = TextEditingController();

  /// The last text the server confirmed (canonical form; empty when none).
  String _saved = '';

  /// The field differs from [_saved]; enables Save.
  bool _dirty = false;

  /// A save/clear request is in flight.
  bool _busy = false;

  /// The server's own count after a fetch/save. Shown while the field still
  /// matches what the server confirmed; the moment the user edits, the
  /// client-side estimate takes over (the server's numbers describe text
  /// the field no longer holds).
  VocabularySettings? _server;

  @override
  void initState() {
    super.initState();
    _rehydrate();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<WhisperModelClient?> _client() async {
    try {
      return await ref.read(whisperModelClientProvider.future);
    } catch (_) {
      return null;
    }
  }

  /// Seeds the editor from the server's saved list. Only while clean: a
  /// fetch racing an in-progress edit must not overwrite what the user is
  /// typing. An unreachable server is not an error banner — the user did
  /// nothing yet; Save will complain if it still cannot reach it.
  Future<void> _rehydrate() async {
    // An unpaired device has no server to ask — and the section is hidden,
    // so a request here would be a request nobody can see the result of.
    bool paired = false;
    try {
      paired = await ref.read(vocabularyPairedProvider.future);
    } catch (_) {
      // Treated as unpaired, same as the provider's own failure path.
    }
    if (!paired || !mounted) return;
    final WhisperModelClient? client = await _client();
    if (client == null || !mounted) return;
    final VocabularySettings settings;
    try {
      settings = await client.fetchVocabulary();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    _adopt(settings);
  }

  void _adopt(VocabularySettings settings) {
    setState(() {
      _server = settings;
      _saved = settings.text;
      if (!_dirty) {
        _controller.text = settings.text;
      }
      _dirty = _controller.text != _saved;
    });
  }

  void _onChanged(String value) {
    final bool dirty = value != _saved;
    // Rebuild on every keystroke: the status line is derived from the text.
    setState(() => _dirty = dirty);
  }

  Future<void> _save() async {
    if (_busy || !_dirty) return;
    // The RAW text goes up; the server canonicalises and we adopt its answer.
    final String text = _controller.text;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final WhisperModelClient? client = await _client();
      if (client == null) {
        throw StateError('no server configured');
      }
      final VocabularySettings settings = await client.setVocabulary(text);
      if (!mounted) return;
      setState(() {
        _server = settings;
        _saved = settings.text;
        _controller.text = settings.text;
        _dirty = false;
      });
      messenger.showSnackBar(
        const SnackBar(content: Text('Vocabulary saved')),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      // 422 carries the rule the list broke ("vocabulary term too long",
      // "too many vocabulary terms") — that IS the message.
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e.statusCode == 422
                ? e.message
                : 'Could not save vocabulary: ${e.message}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Could not save vocabulary: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    if (_busy) return;
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Clear custom vocabulary?'),
            content: const Text(
              'New transcriptions on every device stop using these terms. '
              'Transcripts already written are kept.',
            ),
            actions: <Widget>[
              TextButton(
                key: const ValueKey<String>('vocab-clear-cancel'),
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const ValueKey<String>('vocab-clear-confirm'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Clear'),
              ),
            ],
          ),
        ) ??
        false;
    if (!mounted || !confirmed) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final WhisperModelClient? client = await _client();
      if (client == null) {
        throw StateError('no server configured');
      }
      // Blank text clears server-side (spec §3).
      final VocabularySettings settings = await client.setVocabulary('');
      if (!mounted) return;
      setState(() {
        _server = settings;
        _saved = settings.text;
        _controller.text = settings.text;
        _dirty = false;
      });
      messenger.showSnackBar(
        const SnackBar(content: Text('Vocabulary cleared')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Could not clear vocabulary: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The status line's numbers: the server's when the field holds exactly
  /// what the server confirmed, otherwise the client-side estimate over the
  /// current text with the same rules.
  ({int terms, int tokens, bool over}) _status() {
    final VocabularySettings? server = _server;
    if (!_dirty && server != null && _controller.text == server.text) {
      return (
        terms: server.terms.length,
        tokens: server.tokenEstimate,
        over: server.overBudget,
      );
    }
    final List<String> terms = normalizeVocabulary(_controller.text);
    final int tokens = estimateVocabularyTokens(terms);
    return (
      terms: terms.length,
      tokens: tokens,
      over: tokens > kVocabularyTokenBudget,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool paired = ref.watch(vocabularyPairedProvider).value ?? false;
    if (!paired) return const SizedBox.shrink();

    final ({int terms, int tokens, bool over}) status = _status();
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool canClear =
        !_busy && (_controller.text.isNotEmpty || _saved.isNotEmpty);

    return Padding(
      key: const ValueKey<String>('vocab-section'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text(
            'Custom vocabulary',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'Names, products and jargon your server should spell correctly. '
            'Shared by every device.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey<String>('vocab-editor'),
            controller: _controller,
            enabled: !_busy,
            minLines: 3,
            maxLines: 10,
            keyboardType: TextInputType.multiline,
            onChanged: _onChanged,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText:
                  'One term per line or comma-separated: names, products, '
                  'jargon',
            ),
          ),
          const SizedBox(height: 6),
          Text(
            vocabularyStatusLine(
              termCount: status.terms,
              tokenEstimate: status.tokens,
              overBudget: status.over,
            ),
            key: const ValueKey<String>('vocab-status'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: status.over ? scheme.error : null,
                ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              FilledButton(
                key: const ValueKey<String>('vocab-save'),
                onPressed: _dirty && !_busy ? _save : null,
                child: const Text('Save'),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: const ValueKey<String>('vocab-clear'),
                onPressed: canClear ? _clear : null,
                child: const Text('Clear'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              children: <InlineSpan>[
                const TextSpan(
                  text: 'Applies to every new transcription. Use ',
                ),
                const TextSpan(
                  text: 'Transcribe again',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const TextSpan(
                  text: ' on older recordings to apply it.',
                ),
              ],
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
