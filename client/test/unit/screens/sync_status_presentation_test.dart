// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The sync badge is the last place in the dump screens that painted itself
// outside the Blackout palette: both the list and the detail screen carried
// their own copy of a Material `Colors.green/blue/orange/red/grey` switch.
//
// These tests pin the palette rule itself, not the individual hues, so the
// badge cannot quietly drift back to stock Material colours.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/sync_status.dart';
import 'package:tangent/screens/dump/sync_status_presentation.dart';
import 'package:tangent/theme/tangent_tokens.dart';

void main() {
  // Not `const`: dart:ui Color has no primitive equality, so a const Set is
  // rejected at compile time.
  final Set<Color> palette = <Color>{
    TangentColors.surface,
    TangentColors.sunken,
    TangentColors.panel,
    TangentColors.edge,
    TangentColors.signal,
    TangentColors.record,
    TangentColors.text,
    TangentColors.textDim,
    TangentColors.ink,
  };

  group('the sync badge stays inside the Blackout palette', () {
    test('every status paints with a token, never a stock Material colour', () {
      for (final SyncStatus status in SyncStatus.values) {
        expect(
          palette,
          contains(syncStatusColor(status)),
          reason: '$status paints with a colour outside the palette',
        );
      }
    });

    test('red is reserved: only a genuine failure may use it', () {
      for (final SyncStatus status in SyncStatus.values) {
        if (status == SyncStatus.failed) continue;
        expect(
          syncStatusColor(status),
          isNot(TangentColors.record),
          reason: '$status must not claim the record/fault colour',
        );
      }
      expect(syncStatusColor(SyncStatus.failed), TangentColors.record);
    });

    test('lime is reserved: only work in flight may use it', () {
      for (final SyncStatus status in SyncStatus.values) {
        if (status == SyncStatus.syncing) continue;
        expect(
          syncStatusColor(status),
          isNot(TangentColors.signal),
          reason: '$status is not live and must not use the signal colour',
        );
      }
      expect(syncStatusColor(SyncStatus.syncing), TangentColors.signal);
    });

    test('keeping audio on the device is normal, not a warning', () {
      // Jeff keeps recordings local by choice, so this is the resting state for
      // most rows. It must read as quietly as a synced row.
      expect(syncStatusColor(SyncStatus.localOnly), TangentColors.textDim);
      expect(
        syncStatusColor(SyncStatus.localOnly),
        syncStatusColor(SyncStatus.synced),
      );
    });
  });
}
