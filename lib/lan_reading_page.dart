import 'package:flutter/material.dart';

import 'catalog.dart';
import 'lan_reading_sync.dart';
import 'library_state.dart';

/// Placeholder for the nearby-reading screen: the LAN feature is not part of
/// this build, and this page is unreachable while [LanSyncScope.maybeOf]
/// returns `null`.
class LanReadingPage extends StatelessWidget {
  const LanReadingPage({
    super.key,
    required this.sync,
    required this.reduceMotion,
  });

  final LanReadingSync sync;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('局域网续读')),
      body: const Padding(
        padding: EdgeInsets.all(24),
        child: Text('当前版本未包含局域网续读功能。'),
      ),
    );
  }
}

/// Placeholder sheet for sending the current book to a nearby device.
class LanSendBookSheet extends StatelessWidget {
  const LanSendBookSheet({
    super.key,
    required this.sync,
    required this.book,
    required this.position,
    required this.reduceMotion,
  });

  final LanReadingSync sync;
  final Novel book;
  final ReadingPosition position;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(24),
      child: Text('当前版本未包含局域网续读功能。'),
    );
  }
}