// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db.dart';
import '../dump/dump_detail_screen.dart';
import '../dump/dumps_list_screen.dart';
import '../recording/recording_controller.dart';

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
      if (result != null && mounted) {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => DumpDetailScreen(
            dumpId: result.path.split(RegExp(r'[\\/]')).last.replaceAll('.opus', ''),
            audioPath: result.path,
            durationSeconds: result.durationSeconds,
          ),
        ));
      }
    } else {
      await controller.start();
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
            icon: const Icon(Icons.list),
            tooltip: 'View dumps',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const DumpsListScreen(),
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