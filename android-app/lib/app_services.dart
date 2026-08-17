import 'package:flutter/widgets.dart';

import 'services/connection_controller.dart';
import 'services/device_bridge.dart';
import 'services/discovery_service.dart';
import 'services/file_transfer_service.dart';
import 'services/settings_service.dart';
import 'services/signaling_client.dart';

/// Lightweight DI: exposes the shared app services to every screen through an
/// [InheritedWidget], avoiding a third-party state package.
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

/// Container for all long-lived app services.
class AppServices {
  AppServices({required SettingsService settings})
      : settings = settings,
        bridge = DeviceBridge.instance,
        signaling = SignalingClient.instance,
        discovery = DiscoveryService(),
        controller = ConnectionController(
          bridge: DeviceBridge.instance,
          signaling: SignalingClient.instance,
          discovery: discovery,
          settings: settings,
        );

  final SettingsService settings;
  final DeviceBridge bridge;
  final SignalingClient signaling;
  final DiscoveryService discovery;
  final ConnectionController controller;

  late final FileTransferService files = FileTransferService(bridge);

  /// Wire everything up. Call once from [AppServicesScope] construction.
  Future<void> init() async {
    await controller.init();
  }
}
