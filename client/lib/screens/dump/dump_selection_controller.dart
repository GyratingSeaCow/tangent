// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/storage/storage_contract.dart';

class DumpSelectionController extends StateNotifier<DumpSelectionState> {
  DumpSelectionController()
      : super((
          active: false,
          selectedIds: const {},
          scopeKey: '',
          generation: -1
        ),);
  DumpSelectionState get selection => state;
  Set<String> _eligible = const {};
  bool _settled = false;
  void _set({bool? active, Set<String>? ids, String? scope, int? generation}) {
    state = (
      active: active ?? state.active,
      selectedIds: Set.unmodifiable(ids ?? state.selectedIds),
      scopeKey: scope ?? state.scopeKey,
      generation: generation ?? state.generation
    );
  }

  void apply(
      PresentedDumpResults results, Map<String, Eligibility> eligibility,) {
    if (results.generation < state.generation) return;
    final changed = results.scopeKey != state.scopeKey ||
        results.generation != state.generation;
    _settled = results.settled;
    if (_settled) {
      _eligible = Set.unmodifiable(results.rows
          .where((r) => eligibility[r.id] == Eligibility.eligible)
          .map((r) => r.id),);
    } else if (changed) {
      _eligible = const {};
    }
    _set(
      scope: results.scopeKey,
      generation: results.generation,
      ids: changed
          ? {}
          : _settled
              ? state.selectedIds.intersection(_eligible)
              : state.selectedIds,
    );
  }

  void enter(String id) {
    if (!_settled || !_eligible.contains(id)) return;
    _set(active: true, ids: {id});
  }

  void toggle(String id) {
    if (!state.active || !_settled || !_eligible.contains(id)) return;
    final ids = {...state.selectedIds};
    if (!ids.add(id)) ids.remove(id);
    _set(ids: ids);
  }

  void toggleAll() {
    if (!state.active || !_settled) return;
    _set(ids: state.selectedIds.containsAll(_eligible) ? {} : _eligible);
  }

  void cancel() => _set(active: false, ids: {});
}
