import 'package:flutter/material.dart';

import 'app_services.dart';
import 'screens/dashboard_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/viewer_screen.dart';
import 'theme/app_theme.dart';

/// Root widget for the Windows host app.
class MirrorLinkApp extends StatefulWidget {
  const MirrorLinkApp({super.key, required this.services});

  final AppServices services;

  @override
  State<MirrorLinkApp> createState() => _MirrorLinkAppState();
}

class _MirrorLinkAppState extends State<MirrorLinkApp> {
  @override
  Widget build(BuildContext context) {
    return ServicesScope(
      services: widget.services,
      child: MaterialApp(
        title: 'MirrorLink',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.system,
        initialRoute: DashboardScreen.route,
        routes: {
          DashboardScreen.route: (_) => const DashboardScreen(),
          ViewerScreen.route: (_) => const ViewerScreen(),
          SettingsScreen.route: (_) => const SettingsScreen(),
        },
      ),
    );
  }
}
