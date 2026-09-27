// SPDX-License-Identifier: AGPL-3.0-or-later
/// The v19 -> v20 upgrade: `dumps.speaker_names`, the client `settings`
/// table, and the one-time back-fill of the v1.15.0 rewrite-in-place
/// (docs/design/2026-09-26-speaker-name-map.md §2).
///
/// v1.15.0 wrote names INTO the transcript (`## Jeff`). v1.17.0 keeps the
/// text raw and the names in a map. The back-fill must recover the map,
/// restore the raw labels, mark the row for push, record what it did, and
/// do nothing to rows that were never renamed — including a `## Summary`
/// section heading, which is not a speaker.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:tangent/data/local_db.dart';
import 'package:tangent/models/speaker_names.dart';

/// The v19 dumps shape: every column up to summary_template, no
/// speaker_names, and no settings table.
const String _dumpsV19 = '''
  CREATE TABLE dumps (
    id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    mode TEXT NOT NULL,
    duration_seconds INTEGER NOT NULL,
    title TEXT NOT NULL,
    transcript TEXT,
    meeting_notes TEXT,
    audio_path TEXT NOT NULL,
    audio_size_bytes INTEGER NOT NULL,
    sync_status TEXT NOT NULL,
    sync_attempts INTEGER NOT NULL DEFAULT 0,
    last_sync_error TEXT,
    transcription_status TEXT NOT NULL DEFAULT 'not_transcribed',
    transcription_request_id TEXT,
    transcription_job_id TEXT,
    transcription_attempt INTEGER NOT NULL DEFAULT 0,
    transcription_started_at INTEGER,
    transcription_updated_at INTEGER,
    transcription_completed_at INTEGER,
    transcription_error TEXT,
    folder_id TEXT,
    sync_dirty INTEGER,
    synced_seq INTEGER,
    remote_only INTEGER,
    audio_on_server INTEGER,
    summary TEXT,
    summary_model TEXT,
    summarized_at INTEGER,
    transcript_timings TEXT,
    summary_template TEXT,
    PRIMARY KEY (id)
  );
''';

/// (a) a 2-speaker dump renamed by v1.15.0: headings AND turn prefixes.
const String _renamed = '## Jeff\n'
    'Jeff: Morning. Jeff: is not a prefix here.\n'
    'Talked about Jeff and Sarah in prose.\n'
    '\n'
    '## Sarah\n'
    'Sarah: Sorry I was late.\n'
    '\n'
    '## [unattributed]\n'
    'mumbling\n';

const String _renamedRaw = '## Speaker 1\n'
    'Speaker 1: Morning. Jeff: is not a prefix here.\n'
    'Talked about Jeff and Sarah in prose.\n'
    '\n'
    '## Speaker 2\n'
    'Speaker 2: Sorry I was late.\n'
    '\n'
    '## [unattributed]\n'
    'mumbling\n';

/// (b) a raw diarized dump nobody renamed.
const String _rawDump =
    '## Speaker 1\nSpeaker 1: hi\n\n## Speaker 2\nSpeaker 2: hey\n';

/// (c) a plain dump whose only heading is the `## Summary` section.
const String _summaryOnly =
    'Some brain dump text.\n\n## Summary\n- one point\n';

sqlite3.Database _v19Database() {
  final sqlite3.Database raw = sqlite3.sqlite3.openInMemory();
  raw.execute(_dumpsV19);
  raw.execute('PRAGMA user_version = 19;');
  return raw;
}

void _insert(
  sqlite3.Database raw,
  String id,
  String? transcript, {
  int updatedAt = 200,
  int dirty = 0,
}) {
  raw.execute(
    'INSERT INTO dumps (id, created_at, updated_at, mode, duration_seconds, '
    'title, transcript, audio_path, audio_size_bytes, sync_status, '
    "sync_dirty, synced_seq) VALUES (?, 100, ?, 'meeting', 60, ?, ?, "
    "'/audio/x.opus', 1, 'synced', ?, 7)",
    <Object?>[id, updatedAt, 'Title $id', transcript, dirty],
  );
}

Set<String> _columns(sqlite3.Database sql, String table) => <String>{
      for (final sqlite3.Row row in sql.select("PRAGMA table_info('$table')"))
        row['name'] as String,
    };

Set<String> _tables(sqlite3.Database sql) => <String>{
      for (final sqlite3.Row row
          in sql.select("SELECT name FROM sqlite_master WHERE type='table'"))
        row['name'] as String,
    };

String _record(sqlite3.Database raw) => raw
    .select("SELECT value FROM settings WHERE key = 'speaker_names_backfill'")
    .single['value'] as String;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('v19 -> v20 adds speaker_names and the settings table', () async {
    final sqlite3.Database raw = _v19Database();
    _insert(raw, 'plain', 'just words');
    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);
    await db.listDumps();

    expect(raw.userVersion, 22);
    expect(_columns(raw, 'dumps'), contains('speaker_names'));
    expect(_tables(raw), contains('settings'));
    final DumpRow row = (await db.getDump('plain'))!;
    expect(row.transcript, 'just words');
    expect(row.speakerNames, isNull);
    expect(row.syncDirty, isFalse, reason: 'nothing to back-fill, untouched');
    expect(await db.speakerNamesBackfillRecord(), isNull);
  });

  test('the upgrade is safe when the column and table already exist', () async {
    final sqlite3.Database raw = _v19Database();
    raw.execute('ALTER TABLE dumps ADD COLUMN speaker_names TEXT;');
    raw.execute(
      'CREATE TABLE settings (key TEXT NOT NULL, value TEXT NOT NULL, '
      'PRIMARY KEY (key));',
    );
    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);
    await expectLater(db.listDumps(), completes);
    expect(raw.userVersion, 22);
  });

  test(
      'back-fill: a renamed dump gets the map, raw labels restored, dirty; '
      'a raw dump and a Summary-only dump are untouched', () async {
    final sqlite3.Database raw = _v19Database();
    _insert(raw, 'renamed', _renamed);
    _insert(raw, 'raw', _rawDump);
    _insert(raw, 'summary-only', _summaryOnly);
    _insert(raw, 'no-transcript', null);
    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);
    await db.listDumps();

    // (a) renamed
    final DumpRow renamed = (await db.getDump('renamed'))!;
    expect(
      SpeakerNames.decode(renamed.speakerNames),
      SpeakerNames(
        <String, String>{'Speaker 1': 'Jeff', 'Speaker 2': 'Sarah'},
      ),
    );
    expect(
      renamed.transcript,
      _renamedRaw,
      reason: 'headings and turn prefixes restored; prose untouched',
    );
    expect(renamed.syncDirty, isTrue, reason: 'must reach the server');
    expect(
      renamed.updatedAt.millisecondsSinceEpoch ~/ 1000,
      greaterThan(200),
      reason: 'updated_at bumped so the edit wins on peers',
    );
    expect(renamed.syncedSeq, 7, reason: 'checkpoint left alone');

    // (b) raw
    final DumpRow rawRow = (await db.getDump('raw'))!;
    expect(rawRow.speakerNames, isNull);
    expect(rawRow.transcript, _rawDump);
    expect(rawRow.syncDirty, isFalse);
    expect(rawRow.updatedAt.millisecondsSinceEpoch ~/ 1000, 200);

    // (c) `## Summary` is a section heading, never a speaker
    final DumpRow summary = (await db.getDump('summary-only'))!;
    expect(summary.speakerNames, isNull);
    expect(summary.transcript, _summaryOnly);
    expect(summary.syncDirty, isFalse);

    // null transcript survives
    expect((await db.getDump('no-transcript'))!.transcript, isNull);

    // the record: only the converted dump, names + headings
    final Map<String, dynamic>? record = await db.speakerNamesBackfillRecord();
    expect(record, isNotNull);
    expect(record!.keys, <String>['renamed']);
    expect(record['renamed'], <String, dynamic>{
      'names': <String, dynamic>{'Speaker 1': 'Jeff', 'Speaker 2': 'Sarah'},
      'rewrittenHeadings': <String>['Jeff', 'Sarah'],
    });
    expect(jsonDecode(_record(raw)), record);
  });

  test('(d) idempotent: a second run over the converted rows changes nothing',
      () async {
    final sqlite3.Database raw = _v19Database();
    _insert(raw, 'renamed', _renamed);
    _insert(raw, 'raw', _rawDump);
    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    await db.listDumps();
    final DumpRow first = (await db.getDump('renamed'))!;
    expect(first.transcript, _renamedRaw);
    // Simulate the row having been pushed since, so a second run that
    // touched it would be visible as dirty again.
    raw.execute('UPDATE dumps SET sync_dirty = 0, updated_at = 300');
    final String record = _record(raw);

    // Force the v20 step to run again on the SAME database, as an install
    // that crashed between the back-fill and the version bump would.
    raw.execute('PRAGMA user_version = 19;');
    final LocalDb again = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(again.close);
    await again.listDumps();

    expect(raw.userVersion, 22);
    final DumpRow second = (await again.getDump('renamed'))!;
    expect(second.transcript, _renamedRaw, reason: 'still raw');
    expect(
      SpeakerNames.decode(second.speakerNames).nameFor('Speaker 1'),
      'Jeff',
    );
    expect(second.syncDirty, isFalse, reason: 'nothing rewritten twice');
    expect(second.updatedAt.millisecondsSinceEpoch ~/ 1000, 300);
    expect((await again.getDump('raw'))!.transcript, _rawDump);
    expect(
      _record(raw),
      record,
      reason: 'the undo record is not rewritten either',
    );
  });

  test('back-fill refuses an ambiguous pairing rather than merging speakers',
      () async {
    // A raw `## Speaker 1` AFTER a user heading means position ≠ label; the
    // safe failure is to leave the text alone (nothing is deleted, and the
    // user can name speakers again through the sheet).
    final sqlite3.Database raw = _v19Database();
    const String odd = '## Jeff\nJeff: a\n## Speaker 1\nSpeaker 1: b\n';
    _insert(raw, 'odd', odd);
    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);
    await db.listDumps();
    final DumpRow row = (await db.getDump('odd'))!;
    expect(row.transcript, odd);
    expect(row.speakerNames, isNull);
    expect(row.syncDirty, isFalse);
    expect(await db.speakerNamesBackfillRecord(), isNull);
  });

  group('LocalDb.updateSpeakerNames', () {
    test('writes the map, bumps updated_at, marks dirty, leaves text alone',
        () async {
      final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final DateTime t0 = DateTime.utc(2026, 9, 26, 10);
      await db.applyRemoteDump(
        id: 'd1',
        mode: 'meeting',
        title: 'T',
        transcript: _rawDump,
        meetingNotes: null,
        durationSeconds: 3,
        audioOnServer: true,
        createdAt: t0,
        updatedAt: t0,
        seq: 1,
      );
      final DateTime t1 = DateTime.utc(2026, 9, 26, 11);
      final DumpRow row = await db.updateSpeakerNames(
        'd1',
        SpeakerNames(<String, String>{'Speaker 1': 'Jeff'}),
        now: t1,
      );
      expect(row.speakerNames, '{"Speaker 1":"Jeff"}');
      expect(row.transcript, _rawDump, reason: 'byte-equal: text untouched');
      expect(row.updatedAt.toUtc(), t1);
      expect(row.syncDirty, isTrue);

      final DumpRow cleared = await db.updateSpeakerNames('d1', null);
      expect(cleared.speakerNames, isNull);
      final DumpRow emptied = await db.updateSpeakerNames(
        'd1',
        const SpeakerNames.empty(),
      );
      expect(emptied.speakerNames, isNull, reason: 'empty map = no names');
    });

    test('throws for an unknown dump', () async {
      final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      expect(
        () => db.updateSpeakerNames('nope', const SpeakerNames.empty()),
        throwsStateError,
      );
    });
  });

  test('applyRemoteDump: absent key keeps the map, present null clears it',
      () async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final DateTime t = DateTime.utc(2026, 9, 26);
    Future<void> apply({Object? names = LocalDb.absentSpeakerNamesField}) =>
        db.applyRemoteDump(
          id: 'd1',
          mode: 'brain_dump',
          title: 'T',
          transcript: 'hello',
          meetingNotes: null,
          durationSeconds: 3,
          audioOnServer: true,
          createdAt: t,
          updatedAt: t,
          seq: 1,
          speakerNames: names,
        );

    await apply(names: '{"Speaker 1":"Jeff"}');
    expect((await db.getDump('d1'))!.speakerNames, '{"Speaker 1":"Jeff"}');
    await apply(); // older server: key absent
    expect(
      (await db.getDump('d1'))!.speakerNames,
      '{"Speaker 1":"Jeff"}',
      reason: 'absence is not an eraser',
    );
    await apply(names: null);
    expect(
      (await db.getDump('d1'))!.speakerNames,
      isNull,
      reason: 'an explicit null is authoritative',
    );
  });
}
