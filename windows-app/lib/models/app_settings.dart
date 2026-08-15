/// Desktop app settings (language, notifications, update preferences).
class AppSettings {
  const AppSettings({
    this.language = 'en',
    this.notifications = true,
    this.checkUpdates = true,
    this.autoMinimizeOnConnect = true,
    this.saveDirectory = '',
  });

  final String language;

  /// Show a system toast when a phone connects / a transfer finishes.
  final bool notifications;

  /// Poll the GitHub releases API on startup.
  final bool checkUpdates;

  /// Minimize the dashboard when a viewer window is opened.
  final bool autoMinimizeOnConnect;

  /// Folder for files received from the phone (empty = Documents/MirrorLink).
  final String saveDirectory;

  AppSettings copyWith({
    String? language,
    bool? notifications,
    bool? checkUpdates,
    bool? autoMinimizeOnConnect,
    String? saveDirectory,
  }) {
    return AppSettings(
      language: language ?? this.language,
      notifications: notifications ?? this.notifications,
      checkUpdates: checkUpdates ?? this.checkUpdates,
      autoMinimizeOnConnect: autoMinimizeOnConnect ?? this.autoMinimizeOnConnect,
      saveDirectory: saveDirectory ?? this.saveDirectory,
    );
  }
}
