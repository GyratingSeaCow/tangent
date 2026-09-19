// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/storage/storage_contract.dart';

/// Multi-select over the presented dump list.
///
/// Selection is ACTION-AGNOSTIC: any settled, presented row can be selected,
/// including remote-only rows with no local binding. Selection answers only
/// "which rows did the user mean?" — whether a given action (delete,
/// download, transcribe) can touch a selected row is that action's own
/// eligibility question, answered at execution time. Gating selection on
/// DELETE eligibility (the original design) silently made remote rows
/// unselectable and turned "select all" into "select the deletable few".
///
/// What selection still refuses:
///  * ids that are not in the presented results (scope/generation guard) —
///    acting on rows the user cannot see is how bulk actions eat data;
///  * unsettled results — a list mid-query is not a thing to select from.
class DumpSelectionController extends StateNotifier<DumpSelectionState> {
  DumpSelectionController()
      : super((
          active: false,
          selectedIds: const {},
          scopeKey: '',
          generation: -1
        ),);
  DumpSelectionState get selection => state;
  Set<String> _selectable = const {};
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
      _selectable =
          Set.unmodifiable(results.rows.map((r) => r.id));
    } else if (changed) {
      _selectable = const {};
    }
    _set(
      scope: results.scopeKey,
      generation: results.generation,
      ids: changed
          ? {}
          : _settled
              ? state.selectedIds.intersection(_selectable)
              : state.selectedIds,
    );
  }

  void enter(String id) {
    if (!_settled || !_selectable.contains(id)) return;
    _set(active: true, ids: {id});
  }

  void toggle(String id) {
    if (!state.active || !_settled || !_selectable.contains(id)) return;
    final ids = {...state.selectedIds};
    if (!ids.add(id)) ids.remove(id);
    _set(ids: ids);
  }

  void toggleAll() {
    if (!state.active || !_settled) return;
    _set(ids: state.selectedIds.containsAll(_selectable) ? {} : _selectable);
  }

  void cancel() => _set(active: false, ids: {});
}
