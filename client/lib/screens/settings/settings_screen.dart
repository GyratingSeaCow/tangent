// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../theme/tangent_tokens.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/settings_store.dart';
import '../server/pair_new_device_screen.dart';
import '../server/server_connection_screen.dart';
import 'bulk_import_section.dart';
import 'diagnostics_section.dart';
import 'obsidian_export_section.dart';
import 'reminders_section.dart';
import 'welcome_message_section.dart';
import 'handwriting_search_section.dart';
import 'ai_summaries_section.dart';
import 'auto_file_section.dart';
import 'google_tasks_section.dart';
import 'voices_section.dart';
import 'input_device_section.dart';
import 'mic_gain_section.dart';
import 'storage_settings_section.dart';
import 'trash_screen.dart';
import '../../widgets/instrument_scaffold.dart';
import '../../widgets/top_nav_rail.dart';
import 'custom_vocabulary_section.dart';
import 'whisper_model_section.dart';

/// Instrument Console v2: the nine Settings categories, in overview order.
/// Every v1.40.0 control lives in exactly one of these; none was dropped.
enum SettingsCategory {
  storage('Storage', 'Default folder, local storage and Wi-Fi upload',
      Icons.folder_outlined,),
  transfer('Import & export', 'Bulk audio and Obsidian Markdown',
      Icons.import_export,),
  recording('Recording input', 'Microphone, Bluetooth, gain and trigger',
      Icons.mic_none,),
  server('Server & devices', 'Connection, pairing and trash',
      Icons.cloud_sync_outlined,),
  transcription('Transcription', 'Whisper model and custom vocabulary',
      Icons.subtitles_outlined,),
  intelligence('Intelligence', 'Handwriting, summaries and auto-file',
      Icons.auto_awesome_outlined,),
  integrations('Integrations', 'Google Tasks and remembered voices',
      Icons.hub_outlined,),
  reminders('Reminders', 'Due dates, morning review and completion notices',
      Icons.schedule,),
  maintenance('Maintenance & about', 'Diagnostics, licenses and version',
      Icons.build_outlined,);

  const SettingsCategory(this.title, this.subtitle, this.icon);

  final String title;
  final String subtitle;
  final IconData icon;
}

class SettingsScreen extends ConsumerStatefulWidget {
  /// [category] = the drill to open on first build; null = the overview.
  /// The screen moves between overview and drills IN PLACE (one State, one
  /// load, one SAVE) so an edit in Storage survives a visit to Recording
  /// input exactly as it did on the flat list.
  const SettingsScreen({super.key, this.category});

  final SettingsCategory? category;

  static Key categoryKey(SettingsCategory c) =>
      ValueKey<String>('settings-category-${c.name}');

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  /// Which drill is open; null = the overview. In-place, see [SettingsScreen].
  SettingsCategory? _category;
  TriggerMode _triggerMode = TriggerMode.tap;
  bool _wifiOnly = false;
  // Defaults to true: recordings stay on the device unless the user opts in.
  bool _keepOnDeviceOnly = true;
  bool _keepScreenAwake = true;
  String _serverUrl = '';
  ServerInfoSnapshot? _serverInfo;
  bool _loaded = false;
  bool _serverBusy = false;
  String? _serverError;

  @override
  void initState() {
    super.initState();
    _category = widget.category;
    _load();
    // The footer version comes from the build, never a literal: the old
    // hard-coded 'v1.0.0' footer sat stale for seven releases.
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _appVersion = info.version);
    });
  }

  String _appVersion = '';

  Future<void> _load() async {
    final settings = ref.read(settingsStoreProvider);
    final store = ref.read(secureStoreProvider);
    final url = await store.getServerUrl();
    if (!mounted) return;
    setState(() {
      _triggerMode = settings.triggerMode;
      _wifiOnly = settings.wifiOnlySync;
      _keepOnDeviceOnly = settings.keepRecordingsOnDeviceOnly;
      _keepScreenAwake = settings.keepScreenAwakeWhileRecording;
      _serverUrl = url ?? '';
      _loaded = true;
      _serverBusy = url != null && url.isNotEmpty;
      _serverError = null;
      _serverInfo = null;
    });
    ServerInfoSnapshot? info;
    String? infoError;
    if (url != null && url.isNotEmpty) {
      try {
        final client = ref.read(transcriptionClientProvider);
        info = ServerInfoSnapshot.fromInfo(await client.getServerInfo());
      } catch (e) {
        infoError = e.toString();
      }
    }
    if (mounted) {
      setState(() {
        _serverInfo = info;
        _serverError = infoError;
        _serverBusy = false;
      });
    }
  }

  Future<void> _save() async {
    final settings = ref.read(settingsStoreProvider);
    await settings.setTriggerMode(_triggerMode);
    await settings.setWifiOnlySync(_wifiOnly);
    await settings.setKeepRecordingsOnDeviceOnly(_keepOnDeviceOnly);
    await settings.setKeepScreenAwakeWhileRecording(_keepScreenAwake);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved')),
      );
    }
  }

  Future<void> _changeServer() async {
    await Navigator.of(context).push<void>(MaterialPageRoute<void>(
      builder: (_) => const ServerConnectionScreen(),
    ),);
    await _load();
  }

  Future<void> _refreshServerInfo() async {
    setState(() {
      _serverBusy = true;
      _serverError = null;
    });
    try {
      final client = ref.read(transcriptionClientProvider);
      final info = await client.getServerInfo();
      if (mounted) {
        setState(() => _serverInfo = ServerInfoSnapshot.fromInfo(info));
      }
    } catch (e) {
      if (mounted) setState(() => _serverError = e.toString());
    } finally {
      if (mounted) setState(() => _serverBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final SettingsCategory? category = _category;
    return PopScope(
      // System back from a drill returns to the overview, not out of
      // Settings — the same step the app bar's back arrow takes.
      canPop: category == null,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop && _category != null) setState(() => _category = null);
      },
      child: InstrumentScaffold(
        root: TangentRoot.settings,
        // Settings is a form, not a place you create things from.
        showCreateFab: false,
        maxContentWidth: InstrumentScaffold.readingWidth,
        appBar: AppBar(
          leading: category == null
              ? null
              : IconButton(
                  key: const ValueKey<String>('settings-category-back'),
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Settings',
                  onPressed: () => setState(() => _category = null),
                ),
          title: Text(category?.title ?? 'Settings'),
          actions: [
            TextButton(
              onPressed: _loaded ? _save : null,
              child: const Text('SAVE'),
            ),
          ],
        ),
        body: category == null
            ? _overview(context)
            : ListView(
                padding: const EdgeInsets.only(bottom: 90),
                children: _categoryChildren(context, category),
              ),
      ),
    );
  }

  Widget _overview(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 90),
      children: [
        for (final SettingsCategory c in SettingsCategory.values)
          ListTile(
            key: SettingsScreen.categoryKey(c),
            leading: Icon(c.icon),
            title: Text(c.title),
            subtitle: Text(c.subtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => setState(() => _category = c),
          ),
      ],
    );
  }

  /// The v1.40.0 flat list, partitioned. Each widget appears in exactly one
  /// category; the order inside a category is the order it had before.
  ///
  /// The load gate is also the old one: the independent sections (storage,
  /// import/export, input device, mic gain) render immediately, everything
  /// fed by this screen's own state waits behind 'Loading settings…'.
  List<Widget> _categoryChildren(BuildContext context, SettingsCategory c) {
    final Widget loading = const ListTile(title: Text('Loading settings…'));
    switch (c) {
      case SettingsCategory.storage:
        return [
          const StorageSettingsSection(),
          const Divider(),
          if (!_loaded) loading else ...[
          SwitchListTile(
            title: const Text('Keep recordings on this device'),
            subtitle: const Text(
              'Recordings are never uploaded to the server for storage. '
              'Transcription still works over Wi-Fi or mobile data.',
            ),
            value: _keepOnDeviceOnly,
            onChanged: (v) => setState(() => _keepOnDeviceOnly = v),
          ),
          SwitchListTile(
            title: const Text('Upload recordings only on Wi-Fi'),
            subtitle: Text(
              _keepOnDeviceOnly
                  ? 'No effect while recordings are kept on this device. '
                      'Transcription is never limited to Wi-Fi.'
                  : 'Wait for Wi-Fi before uploading recordings for storage. '
                      'Transcription is exempt and still runs on mobile data.',
            ),
            value: _wifiOnly,
            onChanged: (v) => setState(() => _wifiOnly = v),
          ),
          ],
        ];
      case SettingsCategory.transfer:
        return const [
          BulkImportSection(),
          ObsidianExportSection(),
        ];
      case SettingsCategory.recording:
        return [
          const InputDeviceSection(),
          const MicGainSection(),
          const Divider(),
          if (!_loaded) loading else ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Recording trigger',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          RadioListTile<TriggerMode>(
            title: const Text('Tap to toggle'),
            subtitle: const Text('Tap once to start, tap again to stop'),
            value: TriggerMode.tap,
            groupValue: _triggerMode,
            onChanged: (v) => setState(() => _triggerMode = v!),
          ),
          RadioListTile<TriggerMode>(
            title: const Text('Hold to record'),
            subtitle: const Text('Press and hold the record button'),
            value: TriggerMode.hold,
            groupValue: _triggerMode,
            onChanged: (v) => setState(() => _triggerMode = v!),
          ),
          SwitchListTile(
            title: const Text('Keep screen awake while recording'),
            subtitle: const Text(
              'Prevents screen sleep only while an active recording is running',
            ),
            value: _keepScreenAwake,
            onChanged: (value) => setState(() => _keepScreenAwake = value),
          ),
          ],
        ];
      case SettingsCategory.server:
        if (!_loaded) return [loading];
        return [
          ListTile(
            title: const Text('Server'),
            subtitle: Text(_serverUrl.isEmpty ? '(not set)' : _serverUrl),
            trailing: const Icon(Icons.chevron_right),
            onTap: _serverBusy ? null : _changeServer,
          ),
          ListTile(
            key: const ValueKey<String>('settings-pair-new-device'),
            title: const Text('Pair a new device'),
            subtitle: const Text(
              'Show pairing codes so another device can join this server',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => const PairNewDeviceScreen(),
              ),
            ),
          ),
          ListTile(
            key: const ValueKey<String>('settings-trash'),
            title: const Text('Trash'),
            subtitle:
                const Text('Deleted notebooks — kept 7 days, then emptied'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => const TrashScreen(),
              ),
            ),
          ),
          const WelcomeMessageSection(),
        ];
      case SettingsCategory.transcription:
        if (!_loaded) return [loading];
        return [
          ListTile(
            title: Text(_serverInfo?.title ?? 'Server transcription'),
            subtitle: Text(_serverInfoText()),
            trailing: _serverBusy
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    tooltip: 'Refresh server info',
                    onPressed: _serverUrl.isEmpty ? null : _refreshServerInfo,
                    icon: const Icon(Icons.refresh),
                  ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(
              'Audio is uploaded to your personal Docker container '
              'over the LAN (or cellular). The server transcribes with '
              'faster-whisper and streams the result back. Recordings taken '
              'without connectivity will be queued and transcribed when you '
              'next open the app with network access.',
              style: TextStyle(fontSize: 12, color: TangentColors.textDim),
            ),
          ),
          const WhisperModelSection(),
          const CustomVocabularySection(),
        ];
      case SettingsCategory.intelligence:
        if (!_loaded) return [loading];
        return const [
          HandwritingSearchSection(),
          Divider(),
          AiSummariesSection(),
          Divider(),
          AutoFileSection(),
        ];
      case SettingsCategory.integrations:
        if (!_loaded) return [loading];
        return [
          const GoogleTasksSection(),
          // v1.36.0: reuses the info fetched above — no second round trip.
          VoicesSection(available: _serverInfo?.diarization ?? false),
        ];
      case SettingsCategory.reminders:
        if (!_loaded) return [loading];
        return const [RemindersSection()];
      case SettingsCategory.maintenance:
        if (!_loaded) return [loading];
        return [
          const DiagnosticsSection(),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Licenses'),
            subtitle: const Text(
              'Tangent is AGPL-3.0. View every open-source license this '
              'app is built on.',
            ),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'Tangent',
              applicationVersion:
                  _appVersion.isEmpty ? null : 'v$_appVersion',
              applicationLegalese:
                  'Copyright © 2026 Tangent contributors.\n'
                  'Licensed under the GNU AGPL-3.0-or-later: you have the '
                  'right to receive the source code of this app and of the '
                  'server it talks to.',
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _appVersion.isEmpty
                  ? 'Tangent — AGPL-3.0'
                  : 'Tangent v$_appVersion — AGPL-3.0',
              textAlign: TextAlign.center,
              style: const TextStyle(color: TangentColors.textDim),
            ),
          ),
        ];
    }
  }

  String _serverInfoText() {
    if (_serverBusy) return 'Loading server information…';
    if (_serverError != null) return 'Server unreachable: $_serverError';
    final info = _serverInfo;
    if (info == null) return 'Not configured — tap Server above to set up';
    final parts = <String>['Connected'];
    // Requirement 8: the model list is a real picker now
    // ([WhisperModelSection] below), so the status line is a STATUS line —
    // no 'default model:' note and no 'available:' pseudo-menu that
    // selected nothing.
    if (info.dumpCount != null) parts.add('${info.dumpCount} recordings');
    if (info.setupComplete == false) parts.add('SETUP INCOMPLETE — open the server URL in a browser');
    return parts.join(' · ');
  }
}

class ServerInfoSnapshot {
  const ServerInfoSnapshot({
    required this.setupComplete,
    this.model,
    this.models,
    this.dumpCount,
    this.diarization = false,
  });

  factory ServerInfoSnapshot.fromInfo(dynamic info) {
    return ServerInfoSnapshot(
      setupComplete: info.setupComplete as bool,
      model: info.defaultModel as String?,
      models: (info.availableModels as List?)?.map((e) => e.toString()).toList(),
      dumpCount: info.dumpCount as int?,
      diarization: (info.diarization as bool?) ?? false,
    );
  }

  final bool setupComplete;
  final String? model;
  final List<String>? models;
  final int? dumpCount;

  /// v1.36.0: the server diarizes, so Settings → Voices applies.
  final bool diarization;

  String get title => 'Server transcription';
}

/// Provider for the in-memory settings store.
/// Production wires this up to a persistent implementation in main().
final settingsStoreProvider = Provider<SettingsStore>((ref) => SettingsStore());
