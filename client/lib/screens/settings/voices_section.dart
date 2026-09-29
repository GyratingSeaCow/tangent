// SPDX-License-Identifier: AGPL-3.0-or-later
/// Settings → Voices (v1.36.0 voice matching).
///
/// The server keeps ONE voice book: rename a speaker on any recording and
/// that voice is remembered; the next recording that sounds like them is
/// named automatically. This section lists the remembered names and lets
/// Jeff forget them ONE AT A TIME — there is deliberately no "Forget all".
///
/// Hidden entirely when the server does not diarize (`ServerInfo.diarization`
/// false, or an older server that omits the field): no voices can exist.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/summaries_client.dart';
import '../../theme/tangent_tokens.dart';
import 'ai_summaries_section.dart' show summariesClientProvider;

/// The "taught by N recording(s)" subtitle.
String voiceTaughtLine(int samples) =>
    samples == 1 ? 'taught by 1 recording' : 'taught by $samples recordings';

class VoicesSection extends ConsumerStatefulWidget {
  /// [available] is `ServerInfo.diarization` as already fetched by the
  /// Settings screen — passed in rather than re-fetched so opening Settings
  /// costs one `/v1/server/info` round trip, not two. False (or an older
  /// server that omits the field) hides the section entirely.
  const VoicesSection({super.key, required this.available});

  final bool available;

  @override
  ConsumerState<VoicesSection> createState() => _VoicesSectionState();
}

class _VoicesSectionState extends ConsumerState<VoicesSection> {
  List<VoiceEntry>? _voices;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.available) _refresh();
  }

  @override
  void didUpdateWidget(VoicesSection old) {
    super.didUpdateWidget(old);
    if (widget.available && !old.available) _refresh();
  }

  Future<SummariesClient> _client() => ref.read(summariesClientProvider.future);

  Future<void> _refresh() async {
    final List<VoiceEntry> voices;
    try {
      voices = await (await _client()).listVoices();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load voices: $e');
      return;
    }
    if (!mounted) return;
    setState(() {
      _voices = voices;
      _error = null;
    });
  }

  Future<void> _forget(VoiceEntry voice) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Forget this voice?'),
        content: Text(
          "Forget ${voice.name}'s voice? Recordings already naming "
          '${voice.name} keep their names.',
        ),
        actions: <Widget>[
          TextButton(
            key: const ValueKey<String>('voices-forget-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey<String>('voices-forget-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await (await _client()).forgetVoice(voice.name);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not forget: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.available) return const SizedBox.shrink();

    final List<VoiceEntry>? voices = _voices;
    final String? error = _error;
    return Column(
      key: const ValueKey<String>('voices-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Voices', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Rename a speaker on a recording once and Tangent names them on '
            'the next one. Forget a voice here to stop that for one name.',
            style: TextStyle(fontSize: 12, color: TangentColors.textDim),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    error,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                TextButton(
                  key: const ValueKey<String>('voices-retry'),
                  onPressed: _busy ? null : _refresh,
                  child: const Text('Retry'),
                ),
              ],
            ),
          )
        else if (voices == null)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SizedBox(
              height: 16,
              width: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else if (voices.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'No remembered voices yet. Rename a speaker on a recording and '
              'Tangent will recognise them next time.',
              key: ValueKey<String>('voices-empty'),
              style: TextStyle(fontSize: 12, color: TangentColors.textDim),
            ),
          )
        else
          for (final VoiceEntry voice in voices)
            ListTile(
              key: ValueKey<String>('voice-row-${voice.name}'),
              dense: true,
              title: Text(voice.name),
              subtitle: Text(voiceTaughtLine(voice.samples)),
              trailing: IconButton(
                key: ValueKey<String>('voice-forget-${voice.name}'),
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Forget ${voice.name}',
                onPressed: _busy ? null : () => _forget(voice),
              ),
            ),
      ],
    );
  }
}
