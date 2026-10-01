// SPDX-License-Identifier: AGPL-3.0-or-later
/// User-facing wording for a recording's local-deletion [Eligibility].
///
/// One home for the text so every surface that offers Delete (the
/// Recordings list, the Ask source-chip sheet) explains a refusal the same
/// way. Pure: no widgets, no providers — screens import this, never each
/// other.
library;

import '../data/storage/storage_contract.dart' show Eligibility;

/// Why a recording can or cannot be deleted locally right now. `null` is
/// the not-yet-loaded state.
String eligibilityReason(Eligibility? eligibility) => switch (eligibility) {
      Eligibility.eligible => 'Available for local deletion',
      Eligibility.nonterminal => 'Transcription in progress',
      Eligibility.syncing => 'Sync in progress',
      Eligibility.publicationPending => 'Saving transcript or metadata',
      Eligibility.busy => 'Recording is in use',
      Eligibility.retryOnly =>
        'Local deletion pending; open recording to retry',
      Eligibility.deleting => 'Local deletion in progress',
      Eligibility.denied => 'Storage permission denied',
      Eligibility.unresolved => 'Original storage is unresolved',
      Eligibility.retired => 'Recording already removed',
      Eligibility.missing => 'Recording unavailable',
      null => 'Checking availability',
    };
