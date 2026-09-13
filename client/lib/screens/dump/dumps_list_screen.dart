// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

class DumpsListScreen extends StatelessWidget {
  const DumpsListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dumps')),
      body: const Center(child: Text('No dumps yet')),
    );
  }
}