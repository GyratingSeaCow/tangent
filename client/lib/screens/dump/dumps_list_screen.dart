// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db.dart';
import '../../models/sync_status.dart' show SyncStatus, SyncStatusX;
import 'dump_detail_screen.dart';
import 'dumps_providers.dart';

class DumpsListScreen extends ConsumerStatefulWidget {
  const DumpsListScreen({super.key});

  @override
  ConsumerState<DumpsListScreen> createState() => _DumpsListScreenState();
}

class _DumpsListScreenState extends ConsumerState<DumpsListScreen> {
  final _searchController = TextEditingController();
  bool _searching = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dumpsAsync = ref.watch(dumpsProvider);
    final query = ref.watch(searchQueryProvider);
    final searchAsync = ref.watch(searchResultsProvider);

    final showingSearch = query.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search dumps…',
                  border: InputBorder.none,
                ),
                onChanged: (v) =>
                    ref.read(searchQueryProvider.notifier).state = v,
              )
            : const Text('Dumps'),
        actions: [
          if (_searching)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Close search',
              onPressed: () {
                _searchController.clear();
                ref.read(searchQueryProvider.notifier).state = '';
                setState(() => _searching = false);
              },
            )
          else
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: 'Search',
              onPressed: () => setState(() => _searching = true),
            ),
        ],
      ),
      body: showingSearch
          ? searchAsync.when(
              data: (results) => _DumpList(dumps: results, empty: 'No matches'),
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Search error: $e')),
            )
          : dumpsAsync.when(
              data: (dumps) => _DumpList(
                dumps: dumps,
                empty: 'No dumps yet — record one!',
              ),
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('DB error: $e')),
            ),
    );
  }
}

class _DumpList extends StatelessWidget {
  final List<DumpRow> dumps;
  final String empty;

  const _DumpList({required this.dumps, required this.empty});

  @override
  Widget build(BuildContext context) {
    if (dumps.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(empty, textAlign: TextAlign.center),
        ),
      );
    }
    return ListView.separated(
      itemCount: dumps.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final d = dumps[i];
        final sync = SyncStatusX.fromWire(d.syncStatus);
        return ListTile(
          title: Text(
            d.title.isEmpty ? '(untitled)' : d.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(_subtitleFor(d, sync)),
          trailing: _SyncBadge(status: sync),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => DumpDetailScreen(
                dumpId: d.id,
                audioPath: d.audioPath,
                durationSeconds: d.durationSeconds,
              ),
            ),
          ),
        );
      },
    );
  }

  String _subtitleFor(DumpRow d, SyncStatus s) {
    final mins = (d.durationSeconds / 60).floor();
    final secs = d.durationSeconds % 60;
    final dur = mins > 0 ? '${mins}m ${secs}s' : '${secs}s';
    final date = d.createdAt.toLocal().toString().split('.').first;
    return '$dur · $date';
  }
}

class _SyncBadge extends StatelessWidget {
  final SyncStatus status;
  const _SyncBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      SyncStatus.synced => Colors.green,
      SyncStatus.syncing => Colors.blue,
      SyncStatus.pending => Colors.orange,
      SyncStatus.failed => Colors.red,
      SyncStatus.localOnly => Colors.grey,
    };
    final icon = switch (status) {
      SyncStatus.synced => Icons.cloud_done,
      SyncStatus.syncing => Icons.cloud_sync,
      SyncStatus.pending => Icons.cloud_upload,
      SyncStatus.failed => Icons.cloud_off,
      SyncStatus.localOnly => Icons.smartphone,
    };
    return Icon(icon, color: color, size: 20);
  }
}