// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:tangent/data/local_db.dart';

DumpRow viewRow(String id) => DumpRow(
      id: id,
      createdAt: DateTime.utc(2030),
      updatedAt: DateTime.utc(2030),
      mode: 'brain_dump',
      durationSeconds: 3,
      title: id,
      audioPath: '/synthetic/$id.opus',
      audioSizeBytes: 3,
      syncStatus: 'local_only',
      syncAttempts: 0,
      transcriptionStatus: 'not_transcribed',
      transcriptionAttempt: 0,
    );
