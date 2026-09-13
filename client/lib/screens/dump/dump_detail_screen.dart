// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

class DumpDetailScreen extends StatelessWidget {
  final String dumpId;
  final String audioPath;
  final int durationSeconds;

  const DumpDetailScreen({
    super.key,
    required this.dumpId,
    required this.audioPath,
    required this.durationSeconds,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dump')),
      body: Center(
        child: Text('Dump $dumpId\n$durationSeconds s'),
      ),
    );
  }
}