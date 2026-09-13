// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/audio_storage.dart';
import '../../data/local_db.dart';
import '../dump/dump_detail_screen.dart';
import '../dump/dumps_list_screen.dart';
import '../recording/recording_controller.dart';
import '../settings/settings_screen.dart';
import 'home_providers.dart';

final localDbProvider = Provider<LocalDb>((ref) {
  throw UnimplementedError('Override in main()');
});

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _seconds = 0;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual<RecordingState>(
      recordingControllerProvider,
      (prev, next) {
        if (next == RecordingState.recording) {
          setState(() => _seconds = ref
              .read(recordingControllerProvider.notifier)
              .elapsedSeconds);
        }
      },
    );
  }

  String get _timeLabel {
    final m = (_seconds ~/ 60).toString().padLeft(2, '0');
    final s = (_seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _toggleRecording() async {
    final controller = ref.read(recordingControllerProvider.notifier);
    final state = ref.read(recordingControllerProvider);
    if (state == RecordingState.recording) {
      final result = await controller.stop();
      if (result == null) return;

      // Persist to local DB.
      final db = ref.read(localDbProvider);
      final id = result.path.split(RegExp(r'[\\/]')).last.replaceAll('.opus', '');
      await db.upsertDump(DumpRow(
        id: id,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        mode: 'brain_dump',
        durationSeconds: result.durationSeconds,
        title: '',
        audioPath: result.path,
        audioSizeBytes: result.sizeBytes,
        syncStatus: 'pending',
        syncAttempts: 0,
      ));

      if (mounted) {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => DumpDetailScreen(
            dumpId: id,
            audioPath: result.path,
            durationSeconds: result.durationSeconds,
          ),
        ));
      }
    } else {
      await controller.start();
    }
  }

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    try {
      await ref.read(syncEngineProvider).syncNow();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sync complete')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sync error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(recordingControllerProvider);
    final isRecording = state == RecordingState.recording;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tangent'),
        actions: [
          IconButton(
            icon: _syncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_sync),
            tooltip: 'Sync now',
            onPressed: _syncing ? null : _syncNow,
          ),
          IconButton(
            icon: const Icon(Icons.list),
            tooltip: 'View dumps',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const DumpsListScreen(),
            )),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const SettingsScreen(),
            )),
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _timeLabel,
              style: TextStyle(
                fontSize: 72,
                fontWeight: FontWeight.w200,
                color: isRecording
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 48),
            GestureDetector(
              onTap: _toggleRecording,
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isRecording
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.primary,
                ),
                child: Icon(
                  isRecording ? Icons.stop : Icons.mic,
                  size: 64,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              isRecording ? 'Tap to stop' : 'Tap to record',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}