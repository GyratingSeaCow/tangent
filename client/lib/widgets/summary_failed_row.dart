import 'package:flutter/material.dart';

import '../data/local_db.dart';

/// The red 'Summary failed: reason' line the detail screen shows over
/// the preserved old summary while the server reports
/// `summary_status='failed'` (v1.19.0). Retry re-posts without the
/// picker; dismiss hides it locally until the next failure.
///
/// Every foreground on the banner uses `onErrorContainer`: on the app's
/// M3 dark scheme `error` and `errorContainer` resolve to near-identical
/// reds, so an `error`-coloured label is invisible — the first device
/// check of v1.19.0 showed a banner with no Retry button at all.
class SummaryFailedRow extends StatelessWidget {
  const SummaryFailedRow({
    super.key,
    required this.row,
    required this.onRetry,
    required this.onDismiss,
  });

  final DumpRow row;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String reason = (row.summaryError ?? '').trim();
    return Container(
      key: ValueKey('ai-summary-failed-${row.id}'),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        border: Border.all(color: colors.error),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: colors.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              reason.isEmpty
                  ? 'Summary failed'
                  : 'Summary failed: $reason',
              key: ValueKey('ai-summary-failed-text-${row.id}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: colors.onErrorContainer),
            ),
          ),
          // onErrorContainer, not error: on the M3 dark scheme error and
          // errorContainer resolve to near-identical reds, which rendered
          // this label invisible on the Fold (v1.19.0 device check).
          TextButton(
            key: ValueKey('summary-retry-${row.id}'),
            onPressed: onRetry,
            style: TextButton.styleFrom(
              foregroundColor: colors.onErrorContainer,
              textStyle: const TextStyle(fontWeight: FontWeight.w600),
            ),
            child: const Text('Retry'),
          ),
          IconButton(
            key: ValueKey('summary-dismiss-${row.id}'),
            tooltip: 'Dismiss',
            icon: const Icon(Icons.close, size: 18),
            color: colors.onErrorContainer,
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}
