// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../models/sync_status.dart';
import '../../theme/tangent_tokens.dart';

/// How a [SyncStatus] is painted.
///
/// Shared by the dumps list and the dump detail screen: the two used to carry
/// identical copies of this switch, which is how they drifted out of the
/// Blackout palette together.
///
/// Every status already ships a distinct icon (`cloud_done`, `cloud_sync`,
/// `cloud_upload`, `cloud_off`, `smartphone`), so colour here is redundant
/// reinforcement rather than the only carrier of meaning. That is what lets
/// the resting states share one dim tone without becoming ambiguous.
Color syncStatusColor(SyncStatus status) => switch (status) {
      // Resting states. Nothing is happening and nothing is wrong, so none of
      // these earn a lit colour. `localOnly` in particular is the normal state
      // for a device that keeps its audio on disk by choice — painting it as a
      // warning would nag about a deliberate setting.
      SyncStatus.synced => TangentColors.textDim,
      SyncStatus.pending => TangentColors.textDim,
      SyncStatus.localOnly => TangentColors.textDim,

      // Live: work is in flight right now.
      SyncStatus.syncing => TangentColors.signal,

      // Fault: the only state the user may need to act on.
      SyncStatus.failed => TangentColors.record,
    };
