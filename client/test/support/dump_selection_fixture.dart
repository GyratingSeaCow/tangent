// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'dump_view_fixture.dart';

final presentedFixture =
    StateProvider<AsyncValue<PresentedDumpResults>>((_) => AsyncData((
          scopeKey: 'all',
          generation: 1,
          settled: true,
          rows: [viewRow('fixture-a'), viewRow('fixture-b')],
          limit: null
        ),),);
final eligibilityFixture = StateProvider<Map<String, Eligibility>>((_) =>
    {'fixture-a': Eligibility.eligible, 'fixture-b': Eligibility.eligible},);
DeleteTarget targetFor(String id) => (
      id: id,
      title: id,
      eligibility: Eligibility.eligible,
      retryTicketId: null,
      binding: (
        key: (dumpId: id, incarnation: 'fixture-inc'),
        location: (
          id: 'A',
          label: 'A',
          directory: (
            kind: 'file',
            path: '/synthetic',
            treeUri: '',
            authority: '',
            documentId: ''
          )
        ),
        audio: (kind: 'file', value: '/synthetic/$id.opus'),
        metadataName: '$id.meta.json'
      )
    );
DeletionItemResult itemFor(String id, DeleteState state, {String? ticket}) => (
      id: id,
      state: state,
      audio: (state: ComponentState.removed, problem: null),
      metadata: (
        state: state == DeleteState.deleted
            ? ComponentState.removed
            : ComponentState.failed,
        problem: state == DeleteState.deleted
            ? null
            : (code: ProblemCode.denied, message: 'synthetic denied')
      ),
      ticketId: ticket,
      problem: null
    );

class CountingDeletion implements LocalDeletionService {
  final deletes = <ConfirmedDeletion>[], retries = <ConfirmedDeletionRetry>[];
  final previews = <Set<String>>[];
  Completer<Outcome<DeletionPreview>>? previewGate;
  Completer<Outcome<BulkDeletionResult>>? deleteGate;
  Completer<Outcome<BulkDeletionResult>>? retryGate;
  List<DeleteTarget>? previewTargets;
  BulkDeletionResult? result;
  @override
  Future<Outcome<DeletionPreview>> preview(Set<String> ids) async {
    previews.add(Set.of(ids));
    if (previewGate != null) return previewGate!.future;
    return Ok((targets: previewTargets ?? ids.map(targetFor).toList()));
  }

  @override
  Future<Outcome<BulkDeletionResult>> deleteConfirmed(
      ConfirmedDeletion r,) async {
    deletes.add(r);
    if (deleteGate != null) return deleteGate!.future;
    return Ok(result ??
        (
          items:
              r.targets.map((t) => itemFor(t.id, DeleteState.deleted)).toList(),
          replayed: false
        ),);
  }

  @override
  Future<Outcome<BulkDeletionResult>> retryConfirmed(
      ConfirmedDeletionRetry r,) async {
    retries.add(r);
    if (retryGate != null) return retryGate!.future;
    return Ok(
        (items: [itemFor('fixture-a', DeleteState.deleted)], replayed: false),);
  }

  @override
  Stream<Map<String, Eligibility>> watchEligibility() => const Stream.empty();
}

Future<ProviderContainer> mountSelection(
    WidgetTester tester, CountingDeletion deletion,
    {void Function(BuildContext, dynamic)? onOpen,
    double textScale = 1,
    bool nestedRoute = false,}) async {
  final container = ProviderContainer(
    overrides: [
      presentedDumpsProvider.overrideWith((ref) => ref.watch(presentedFixture)),
      deletionEligibilityProvider
          .overrideWith((ref) => Stream.value(ref.watch(eligibilityFixture))),
      localDeletionServiceProvider.overrideWithValue(deletion),
      // Baseline sources allow behaviorally red rendering against the old screen.
      filteredDumpsProvider.overrideWith(
          (ref) => ref.watch(presentedFixture).whenData((r) => r.rows),),
      searchResultsProvider.overrideWith((_) => const Stream.empty()),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
  });
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: navigator,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,),
        home: nestedRoute
            ? const Scaffold(body: Text('Fixture home'))
            : DumpsListScreen(onOpenDump: onOpen),
      ),
    ),
  );
  if (nestedRoute) {
    unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => DumpsListScreen(onOpenDump: onOpen),),),);
  }
  await pumpSelection(tester);
  return container;
}

Future<void> pumpSelection(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}
