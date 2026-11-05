import 'package:flutter/widgets.dart';

import 'lan_reading_sync.dart';

/// Wraps the app so nearby receipts can interrupt the current screen.
///
/// Nearby reading is unavailable in this build, so the monitor is a pass-through
/// that never shows a notice.
class LanHandoffMonitor extends StatefulWidget {
  const LanHandoffMonitor({
    super.key,
    required this.handoff,
    required this.onContinue,
    required this.reduceMotion,
    required this.noticeWrapper,
    required this.child,
  });

  final LanHandoff? handoff;
  final Future<void> Function(LanHandoffReceipt receipt) onContinue;
  final bool reduceMotion;
  final Widget Function(Widget notice) noticeWrapper;
  final Widget child;

  @override
  State<LanHandoffMonitor> createState() => _LanHandoffMonitorState();
}

class _LanHandoffMonitorState extends State<LanHandoffMonitor> {
  @override
  Widget build(BuildContext context) => widget.child;
}