// SPDX-License-Identifier: AGPL-3.0-or-later
/// `SpeakerNames` (v1.17.0 spec §1): the per-recording name map.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/speaker_names.dart';

void main() {
  test('round-trips through JSON', () {
    final SpeakerNames names = SpeakerNames(
      <String, String>{'Speaker 1': 'Jeff', 'Speaker 2': 'Sarah'},
    );
    final Map<String, dynamic> json = names.toJson();
    expect(json, <String, dynamic>{'Speaker 1': 'Jeff', 'Speaker 2': 'Sarah'});
    expect(SpeakerNames.fromJson(json), names);
    expect(SpeakerNames.decode(names.encode()), names);
    expect(
      jsonDecode(names.encode()!),
      <String, dynamic>{'Speaker 1': 'Jeff', 'Speaker 2': 'Sarah'},
    );
  });

  test('nameFor falls back to the raw label', () {
    final SpeakerNames names =
        SpeakerNames(<String, String>{'Speaker 1': 'Jeff'});
    expect(names.nameFor('Speaker 1'), 'Jeff');
    expect(names.nameFor('Speaker 2'), 'Speaker 2');
    expect(names.nameFor('[unattributed]'), '[unattributed]');
    expect(const SpeakerNames.empty().nameFor('Speaker 1'), 'Speaker 1');
  });

  test('withRename adds, replaces, and a blank name removes the key', () {
    final SpeakerNames base =
        SpeakerNames(<String, String>{'Speaker 1': 'Jeff'});
    final SpeakerNames two = base.withRename('Speaker 2', '  Sarah   Lee ');
    expect(two.nameFor('Speaker 2'), 'Sarah Lee', reason: 'normalised');
    expect(base.hasName('Speaker 2'), isFalse, reason: 'immutable');
    expect(
      two.withRename('Speaker 1', 'Jeffrey').nameFor('Speaker 1'),
      'Jeffrey',
    );
    final SpeakerNames removed = two.withRename('Speaker 1', '   ');
    expect(removed.hasName('Speaker 1'), isFalse);
    expect(removed.entries, <String, String>{'Speaker 2': 'Sarah Lee'});
    expect(removed.without('Speaker 2').isEmpty, isTrue);
  });

  test('isEmpty, and empty encodes as null (the "no names" column value)', () {
    expect(const SpeakerNames.empty().isEmpty, isTrue);
    expect(
      SpeakerNames(<String, String>{'Speaker 1': ''}).isEmpty,
      isTrue,
      reason: 'blank names never enter the map',
    );
    expect(const SpeakerNames.empty().encode(), isNull);
    expect(SpeakerNames(<String, String>{'Speaker 1': 'A'}).isEmpty, isFalse);
  });

  test('value equality ignores insertion order; hash agrees', () {
    final SpeakerNames a =
        SpeakerNames(<String, String>{'Speaker 1': 'A', 'Speaker 2': 'B'});
    final SpeakerNames b =
        SpeakerNames(<String, String>{'Speaker 2': 'B', 'Speaker 1': 'A'});
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(SpeakerNames(<String, String>{'Speaker 1': 'A'})));
    expect(a, isNot(a.withRename('Speaker 2', 'C')));
  });

  test('decode tolerates null, blank, malformed and non-object JSON', () {
    expect(SpeakerNames.decode(null), const SpeakerNames.empty());
    expect(SpeakerNames.decode('   '), const SpeakerNames.empty());
    expect(SpeakerNames.decode('{not json'), const SpeakerNames.empty());
    expect(SpeakerNames.decode('[1,2]'), const SpeakerNames.empty());
    expect(
      SpeakerNames.decode('{"Speaker 1": 7, "Speaker 2": "Ann"}'),
      SpeakerNames(<String, String>{'Speaker 2': 'Ann'}),
      reason: 'non-string values are ignored',
    );
  });
}
