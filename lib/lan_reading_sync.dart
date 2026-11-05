import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catalog.dart';
import 'library_state.dart';

/// A nearby-handoff token sent from another device.
///
/// The reference snapshot did not include the original LAN reading
/// implementation, so this build keeps the type surface but leaves the feature
/// dormant: [LanReadingSync.handoff] is always `null`.
class LanHandoffReceipt {
  const LanHandoffReceipt({this.online});

  /// Identifier of the online book this receipt belongs to, when the sender was
  /// reading an online novel instead of a local file.
  final String? online;

  @override
  bool operator ==(Object other) =>
      other is LanHandoffReceipt && other.online == online;

  @override
  int get hashCode => online.hashCode;
}

/// A resolved receipt: which book, and where to continue reading.
typedef LanHandoffTarget = ({Novel book, ReadingPosition position});

/// Receives receipts from nearby devices.
abstract class LanHandoff {
  /// Most recent receipt waiting for the user's confirmation, if any.
  LanHandoffReceipt? get received;

  /// Resolves [receipt] into a concrete book and position.
  Future<LanHandoffTarget> resolveReceipt(LanHandoffReceipt receipt);

  /// Dismisses the pending receipt without continuing.
  void dismissReceipt();
}

/// Coordinates nearby "continue reading on this device" handoffs.
///
/// Only the plumbing the rest of the app talks to is implemented here; the
/// networking layer is unavailable in this build, so [handoff] stays `null` and
/// every call site degrades to its non-LAN behaviour.
class LanReadingSync {
  LanReadingSync({
    required LibraryState state,
    required SharedPreferences preferences,
    required Object? books,
    required Object? repository,
  }) : _books = books,
       _repository = repository;

  final Object? _books;
  final Object? _repository;

  /// Local book store handed in by the app shell (`null` when unavailable).
  Object? get books => _books;

  /// Repository handed in by the app shell (`null` when unavailable).
  Object? get repository => _repository;

  /// Always `null`: nearby reading is not part of this build.
  LanHandoff? get handoff => null;

  Future<void> initialize() async {}

  void dispose() {}
}

/// Exposes [LanReadingSync] to the widget tree.
///
/// [maybeOf] returns `null` while nearby reading is unavailable, which hides the
/// settings entry and the reader handoff action.
class LanSyncScope extends InheritedWidget {
  const LanSyncScope({super.key, required this.sync, required super.child});

  final LanReadingSync? sync;

  static LanReadingSync? maybeOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<LanSyncScope>();
    final sync = scope?.sync;
    return sync != null && sync.handoff != null ? sync : null;
  }

  @override
  bool updateShouldNotify(LanSyncScope oldWidget) => oldWidget.sync != sync;
}