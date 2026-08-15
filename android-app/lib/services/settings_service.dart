import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';

/// Persists [AppSettings] to shared_preferences.
class SettingsService extends ChangeNotifier {
  SettingsService();

  AppSettings _app = const AppSettings();

  /// Current settings snapshot.
  AppSettings get app => _app;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _app = AppSettings(
      quality: _quality(prefs.getString('quality')),
      fps: _fps(prefs.getString('fps')),
      themeMode: _theme(prefs.getString('theme')),
      autoStart: prefs.getBool('auto_start') ?? false,
      clipboardSync: prefs.getBool('clipboard_sync') ?? true,
      autoQuality: prefs.getBool('auto_quality') ?? true,
      allowDiagnostics: prefs.getBool('allow_diagnostics') ?? false,
      deviceNickname: prefs.getString('device_nickname') ?? '',
    );
    notifyListeners();
  }

  Future<void> update(AppSettings next) async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setString('quality', next.quality.name),
      prefs.setString('fps', next.fps.name),
      prefs.setString('theme', next.themeMode.name),
      prefs.setBool('auto_start', next.autoStart),
      prefs.setBool('clipboard_sync', next.clipboardSync),
      prefs.setBool('auto_quality', next.autoQuality),
      prefs.setBool('allow_diagnostics', next.allowDiagnostics),
      prefs.setString('device_nickname', next.deviceNickname),
    ]);
    _app = next;
    notifyListeners();
  }

  VideoQuality _quality(String? v) => switch (v) {
        'high' => VideoQuality.high,
        'low' => VideoQuality.low,
        _ => VideoQuality.medium,
      };

  CaptureFps _fps(String? v) =>
      v == 'fps60' ? CaptureFps.fps60 : CaptureFps.fps30;

  ThemeSetting _theme(String? v) => switch (v) {
        'light' => ThemeSetting.light,
        'dark' => ThemeSetting.dark,
        _ => ThemeSetting.system,
      };
}
