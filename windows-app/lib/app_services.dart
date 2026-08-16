import 'dart:io';

import 'package:flutter/widgets.dart';

import 'services/clipboard_sync.dart';
import 'services/discovery_broadcaster.dart';
import 'services/release_checker.dart';
import 'services/session_manager.dart';
import 'services/settings_service.dart';
import 'services/signaling_server.dart';

/// Lightweight DI scope (same pattern as the Android app).
class ServicesScope extends InheritedWidget {
  const ServicesScope({
    super.key,
    required this.services,
    required super.child,
  });

  final AppServices services;

  static AppServices of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ServicesScope>();
    assert(scope != null, 'ServicesScope not found in widget tree');
    return scope!.services;
  }

  @override
  bool updateShouldNotify(ServicesScope oldWidget) =>
      oldWidget.services != services;
}

/// Container for all long-lived host services.
class AppServices {
  AppServices({required this.settings})
      : signaling = SignalingServer(),
        discovery = DiscoveryBroadcaster(),
        releaseChecker = ReleaseChecker() {
    session = SessionManager(settings: settings);
    clipboardSync = ClipboardSync(session);
  }

  final SettingsService settings;
  final SignalingServer signaling;
  final DiscoveryBroadcaster discovery;
  late final SessionManager session;
  late final ClipboardSync clipboardSync;
  final ReleaseChecker releaseChecker;

  String get pcName {
    try {
      final host = Platform.localHostname;
      return host.isEmpty ? 'Windows PC' : host;
    } catch (_) {
      return 'Windows PC';
    }
  }

  Future<void> init() async {
    await signaling.start();
    session.attach(signaling);
    session.onIncomingClipboard = clipboardSync.onIncoming;
    await discovery.start(
      deviceName: pcName,
      signalingPort: 59661,
    );
    clipboardSync.start();
  }

  /// Regenerate the pairing code and re-broadcast discovery beacons so phones
  /// can find this PC again (manual refresh).
  Future<void> refreshDiscovery() async {
    signaling.regenerateCode();
    await discovery.start(
      deviceName: pcName,
      signalingPort: 59661,
    );
  }

  Future<void> dispose() async {
    clipboardSync.stop();
    await discovery.stop();
    await session.close();
    await signaling.stop();
  }
}
