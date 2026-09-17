// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/services/recording_service.dart';

// Presentation seam only; real reservation/publication is tested with SQLite/files.
class WidgetRecordingCoordinator implements RecordingCoordinator {
  WidgetRecordingCoordinator(this.recorder);
  final RecordingService recorder;
  @override
  Stream<RecordingLifecycleState> watchState() => const Stream.empty();
  @override
  Future<Outcome<CaptureReservation>> start({required String mode}) async {
    final path = await recorder.start(stagingPath: '/fixture/widget.opus');
    return Ok(
      (
        id: 'fixture-widget',
        key: (dumpId: 'fixture-widget', incarnation: 'fixture-incarnation'),
        location: (
          id: 'fixture-location',
          label: 'fixture',
          directory: (
            kind: 'file',
            path: '/fixture',
            authority: '',
            treeUri: '',
            documentId: ''
          )
        ),
        stagingPath: path,
        mode: mode,
        startedAt: DateTime.utc(2030),
        phase: CapturePhase.recording
      ),
    );
  }

  @override
  Future<Outcome<DumpRow?>> stopAndPersist() async {
    await recorder.stop();
    return const Ok(null);
  }
}
