import 'package:flutter/material.dart';

import 'app_services.dart';
import 'models/app_settings.dart';
import 'screens/home_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/splash_screen.dart';
import 'theme/app_theme.dart';

/// Root widget. Owns the [AppServices] and wires theme mode into the
/// app-wide [ThemeMode] so dark/light selection applies instantly.
class MirrorLinkApp extends StatefulWidget {
  const MirrorLinkApp({super.key, required this.services});

  final AppServices services;

  @override
  State<MirrorLinkApp> createState() => _MirrorLinkAppState();
}

class _MirrorLinkAppState extends State<MirrorLinkApp> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _applyThemeMode();
    widget.services.settings.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    widget.services.settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() => _applyThemeMode();

  void _applyThemeMode() {
    final mode = widget.services.settings.app.themeMode;
    setState(() {
      _themeMode = mode == ThemeSetting.light
          ? ThemeMode.light
          : mode == ThemeSetting.dark
              ? ThemeMode.dark
              : ThemeMode.system;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ServicesScope(
      services: widget.services,
      child: MaterialApp(
        title: 'MirrorLink',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: _themeMode,
        initialRoute: SplashScreen.route,
        routes: {
          SplashScreen.route: (_) => const SplashScreen(),
          HomeScreen.route: (_) => const HomeScreen(),
          PairingScreen.route: (_) => const PairingScreen(),
          SettingsScreen.route: (_) => const SettingsScreen(),
        },
      ),
    );
  }
}
