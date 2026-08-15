import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/device.dart';

/// Persists desktop settings and the connection history.
class SettingsService extends ChangeNotifier {
  AppSettings _app = const AppSettings();
  List<ConnectionRecord> _history = [];

  AppSettings get app => _app;
  List<ConnectionRecord> get history => List.unmodifiable(_history);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _app = AppSettings(
      language: prefs.getString('language') ?? 'en',
      notifications: prefs.getBool('notifications') ?? true,
      checkUpdates: prefs.getBool('check_updates') ?? true,
      autoMinimizeOnConnect:
          prefs.getBool('auto_minimize_on_connect') ?? true,
      saveDirectory: prefs.getString('save_directory') ?? '',
    );
    try {
      final raw = prefs.getString('history');
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        _history = list
            .map((e) => ConnectionRecord.fromJson(Map<String, dynamic>.from(e)))
            .toList()
            .reversed
            .toList();
      }
    } catch (_) {
      _history = [];
    }
    notifyListeners();
  }

  Future<void> update(AppSettings next) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('language', next.language);
    await prefs.setBool('notifications', next.notifications);
    await prefs.setBool('check_updates', next.checkUpdates);
    await prefs.setBool('auto_minimize_on_connect', next.autoMinimizeOnConnect);
    await prefs.setString('save_directory', next.saveDirectory);
    _app = next;
    notifyListeners();
  }

  Future<void> addHistory(ConnectionRecord record) async {
    _history = [record, ..._history].take(50).toList();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'history',
      jsonEncode(_history.map((e) => e.toJson()).toList()),
    );
  }
}
