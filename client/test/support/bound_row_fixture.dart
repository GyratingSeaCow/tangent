// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_codec.dart';
import 'storage_fixture.dart';

/// Deterministic test identity, captured by fixtures rather than looked up by
/// production callbacks. Only synthetic test rows use this seeding API.
RecordingKey fileFixtureKey(String id) =>
    (dumpId: id, incarnation: 'fixture-incarnation-$id');

Future<BoundRecording> seedFileFixtureRow(LocalDb db, DumpRow row) async {
  final existing = await db.boundRecording(row.id);
  // Direct fixture setup is deliberately separate from guarded production upsert.
  await db.into(db.dumps).insertOnConflictUpdate(row);
  if (existing != null) return existing;
  final directory = fileLocation(
    'fixture-location-${const Uuid().v4()}',
    p.dirname(row.audioPath),
  );
  final canonical = StorageCodec.canonicalKey(directory.directory);
  final known = await (db.select(db.storageLocations)
        ..where((l) => l.canonicalKey.equals(canonical)))
      .getSingleOrNull();
  if (known == null) {
    await db.customStatement(
        'INSERT INTO storage_locations(id,canonical_key,directory_json,label) VALUES(?,?,?,?)',
        [
          directory.id,
          canonical,
          StorageCodec.encodeDirectory(directory.directory),
          directory.label,
        ]);
  }
  final binding = (
    key: fileFixtureKey(row.id),
    location: (
      id: known?.id ?? directory.id,
      label: known?.label ?? directory.label,
      directory: directory.directory
    ),
    audio: (kind: 'file', value: row.audioPath),
    metadataName: '${row.id}.meta.json'
  );
  await db.bindRecording(binding);
  return binding;
}
