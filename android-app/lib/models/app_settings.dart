/// Stream quality presets. `height` is the *maximum* capture height; the
/// width is derived from the display aspect ratio.
enum VideoQuality {
  low('Low', 480),
  medium('Medium', 720),
  high('High', 1080);

  const VideoQuality(this.label, this.height);
  final String label;
  final int height;
}

/// Capture frame rate.
enum CaptureFps {
  fps30('30 FPS', 30),
  fps60('60 FPS', 60);

  const CaptureFps(this.label, this.value);
  final String label;
  final int value;
}

/// App theme preference.
enum ThemeSetting {
  system('System'),
  light('Light'),
  dark('Dark');

  const ThemeSetting(this.label);
  final String label;
}

/// Serialisable app settings object, mirroring the shared_preferences keys
/// used by [SettingsService].
class AppSettings {
  const AppSettings({
    this.quality = VideoQuality.medium,
    this.fps = CaptureFps.fps30,
    this.themeMode = ThemeSetting.system,
    this.autoStart = false,
    this.clipboardSync = true,
    this.autoQuality = true,
    this.allowDiagnostics = false,
    this.deviceNickname = '',
  });

  final VideoQuality quality;
  final CaptureFps fps;
  final ThemeSetting themeMode;

  /// Start mirroring automatically when a paired PC is detected.
  final bool autoStart;

  /// Sync clipboard both ways while connected.
  final bool clipboardSync;

  /// Native side adapts capture resolution when frame rate drops.
  final bool autoQuality;

  /// Privacy: send anonymous crash diagnostics (off by default).
  final bool allowDiagnostics;

  /// Optional nickname shown on the PC dashboard.
  final String deviceNickname;

  AppSettings copyWith({
    VideoQuality? quality,
    CaptureFps? fps,
    ThemeSetting? themeMode,
    bool? autoStart,
    bool? clipboardSync,
    bool? autoQuality,
    bool? allowDiagnostics,
    String? deviceNickname,
  }) {
    return AppSettings(
      quality: quality ?? this.quality,
      fps: fps ?? this.fps,
      themeMode: themeMode ?? this.themeMode,
      autoStart: autoStart ?? this.autoStart,
      clipboardSync: clipboardSync ?? this.clipboardSync,
      autoQuality: autoQuality ?? this.autoQuality,
      allowDiagnostics: allowDiagnostics ?? this.allowDiagnostics,
      deviceNickname: deviceNickname ?? this.deviceNickname,
    );
  }
}
