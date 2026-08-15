import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'app_services.dart';
import 'services/settings_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  final settings = SettingsService();
  await settings.load();

  final services = AppServices(settings: settings);
  await services.init();

  runApp(MirrorLinkApp(services: services));
}
