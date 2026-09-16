// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/screens/dump/local_deletion_presentation.dart';
import '../../../support/dump_selection_fixture.dart' show targetFor;

const denied = (code: ProblemCode.denied, message: 'synthetic denied');
DeletionItemResult item(String id, String? ticket, {
  DeleteState state = DeleteState.failed,
  ComponentState audio = ComponentState.removed,
  ComponentState metadata = ComponentState.failed,
  StorageProblem? problem,
  StorageProblem? componentProblem,
}) => (id: id, ticketId: ticket, state: state,
  audio: (state: audio, problem: null),
  metadata: (state: metadata, problem: componentProblem), problem: problem);
BulkDeletionResult batch(List<DeletionItemResult> items, {bool replayed = false}) => (items: items, replayed: replayed);

void main() {
  DeleteTarget discoveredTarget(String id, String ticket) {
    final target = targetFor(id);
    return (id: id, title: id, binding: target.binding,
        eligibility: Eligibility.retryOnly, retryTicketId: ticket);
  }
  test('I1-I1 discovery owns identity only, preserves totals and richer receipts', () {
    final s = LocalDeletionRecoveryState();
    final target = discoveredTarget('fixture-a', 'ta');
    expect(s.discover(target), isTrue);
    expect(s.discover(target), isTrue);
    expect(s.latest, isNull); expect(s.pending, isEmpty);
    expect(s.discovered, [target]); expect(s.ticketIds, ['ta']);
    final captured = s.ticketIds;
    expect(() => s.discovered.clear(), throwsUnsupportedError);
    expect(() => captured.clear(), throwsUnsupportedError);
    final receipt = item('fixture-a', 'ta', componentProblem: denied);
    s.record(batch([receipt], replayed: true));
    expect(s.discovered, isEmpty); expect(s.pending, [receipt]);
    expect(s.discover(target), isTrue);
    expect(s.pending, [receipt]); expect(s.latest!.replayed, isTrue);
    s.record(batch([item('fixture-b', 'tb', state: DeleteState.deleted, metadata: ComponentState.absent)]));
    expect(s.pending, [receipt]); expect(s.ticketIds, captured);
    expect(s.latest!.items.single.id, 'fixture-b');
    s.record(batch([item('fixture-a', 'ta', state: DeleteState.deleted, metadata: ComponentState.absent)]));
    expect(s.hasPending, isFalse);
    expect(s.discover(target), isFalse, reason: 'late snapshot cannot resurrect settled exact ticket');
    s.record(batch([receipt], replayed: true));
    expect(s.hasPending, isFalse);
  });
  test('I1-I1 discovery rejects invalid and conflicting identity without erasure', () {
    final s = LocalDeletionRecoveryState();
    final target = discoveredTarget('fixture-a', 'ta');
    s.discover(target);
    final invalid = <DeleteTarget>[
      targetFor('fixture-a'),
      (id: target.id, title: target.title, binding: null, eligibility: Eligibility.retryOnly, retryTicketId: 'ta'),
      (id: target.id, title: target.title, binding: target.binding, eligibility: Eligibility.retryOnly, retryTicketId: null),
      (id: 'wrong', title: target.title, binding: target.binding, eligibility: Eligibility.retryOnly, retryTicketId: 'ta'),
      discoveredTarget('fixture-other', 'ta'),
      (id: target.id, title: target.title, binding: (key: (dumpId: target.id, incarnation: 'changed'), location: target.binding!.location, audio: target.binding!.audio, metadataName: target.binding!.metadataName), eligibility: Eligibility.retryOnly, retryTicketId: 'ta'),
    ];
    for (final value in invalid) {
      expect(s.discover(value), isFalse); expect(s.discovered, [target]);
      expect(s.ticketIds, ['ta']); expect(s.latest, isNull);
    }
    s.record(batch([item('wrong', 'ta', state: DeleteState.deleted, metadata: ComponentState.absent)]));
    expect(s.discovered, [target]);
    s.record(batch([])); expect(s.discovered, [target]);
    s.record(batch([item('fixture-a', null, state: DeleteState.skipped)]));
    expect(s.discovered, [target]);
  });
  test('recovery snapshots are immutable and independent of latest result', () {
    final s = LocalDeletionRecoveryState();
    final original = item('a', 'ta'); final input = [original];
    s.record(batch(input)); input.clear();
    final ids = s.ticketIds, pending = s.pending;
    expect(s.latest!.items, [original]);
    expect(() => s.latest!.items.clear(), throwsUnsupportedError);
    expect(() => ids.add('wrong'), throwsUnsupportedError);
    expect(() => pending.clear(), throwsUnsupportedError);
    s.record(batch([item('b', 'tb')]));
    expect(ids, ['ta']); expect(pending, [original]);
    expect(s.ticketIds, ['ta', 'tb']);
    expect(s.latest!.items.map((i) => i.id), ['b']);
  });
  test('multiple tickets survive unrelated success ticketless skip and partial retry', () {
    final s = LocalDeletionRecoveryState();
    final a = item('a', 'ta'), b = item('b', 'tb'), c = item('c', 'tc');
    s.record(batch([a,b,c]));
    s.record(batch([item('other', 'other-ticket', state: DeleteState.deleted, metadata: ComponentState.removed), item('a', null, state: DeleteState.skipped)]));
    expect(s.pending, [a,b,c]);
    s.record(batch([item('a', 'ta', state: DeleteState.deleted, metadata: ComponentState.absent), item('b', 'tb', metadata: ComponentState.unknown)], replayed: true));
    expect(s.ticketIds, ['tb','tc']);
    expect(s.pending.first.metadata.state, ComponentState.unknown);
    expect(s.pending.last, c); expect(s.latest!.replayed, isTrue);
    expect(s.latest!.items, hasLength(2));
    for (var n = 0; n < 10; n++) { s.record(batch([b], replayed: true)); }
    expect(s.pending, [b,c]);
    s.record(batch([])); expect(s.pending, [b,c]);
    s.record(batch([item('b', 'tb', state: DeleteState.deleted, metadata: ComponentState.removed)]));
    expect(s.ticketIds, ['tc']);
    s.record(batch([item('c', 'tc', state: DeleteState.deleted, audio: ComponentState.absent, metadata: ComponentState.removed)]));
    expect(s.hasPending, isFalse);
  });
  final ambiguous = <String, DeletionItemResult>{
    'ticketless success': item('a', null, state: DeleteState.deleted, metadata: ComponentState.removed),
    'same dump different ticket': item('a', 'wrong-ticket', state: DeleteState.deleted, metadata: ComponentState.removed),
    'same ticket different dump': item('wrong-dump', 'ta', state: DeleteState.deleted, metadata: ComponentState.removed),
    'skipped exact ticket': item('a', 'ta', state: DeleteState.skipped, metadata: ComponentState.removed),
    'incomplete components': item('a', 'ta', state: DeleteState.deleted, metadata: ComponentState.unknown),
    'aggregate problem': item('a', 'ta', state: DeleteState.deleted, metadata: ComponentState.removed, problem: denied),
    'component problem': item('a', 'ta', state: DeleteState.deleted, metadata: ComponentState.removed, componentProblem: denied),
  };
  for (final entry in ambiguous.entries) {
    test('fail closed for ${entry.key}', () {
      final s = LocalDeletionRecoveryState(); final original = item('a', 'ta');
      s.record(batch([original])); s.record(batch([entry.value]));
      expect(s.pending, [original]); expect(s.ticketIds, ['ta']);
      expect(s.latest!.items, [entry.value]);
    });
  }
}
