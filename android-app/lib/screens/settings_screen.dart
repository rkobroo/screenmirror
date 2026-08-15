import 'package:flutter/material.dart';

import '../app_services.dart';
import '../models/app_settings.dart';

/// Settings: video quality, FPS, theme, startup and privacy options.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const route = '/settings';

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context);
    final settings = services.settings;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: AnimatedBuilder(
        animation: settings,
        builder: (context, _) {
          final app = settings.app;
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              _SectionHeader('Streaming'),
              _RadioGroup<VideoQuality>(
                title: 'Video quality',
                icon: Icons.hd,
                options: VideoQuality.values,
                value: app.quality,
                label: (q) => q.label,
                onChanged: (v) =>
                    settings.update(app.copyWith(quality: v!)),
              ),
              _RadioGroup<CaptureFps>(
                title: 'Frame rate',
                icon: Icons.speed,
                options: CaptureFps.values,
                value: app.fps,
                label: (f) => f.label,
                onChanged: (v) => settings.update(app.copyWith(fps: v!)),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.autorenew),
                title: const Text('Auto quality'),
                subtitle: const Text(
                    'Lower capture resolution automatically when frames drop.'),
                value: app.autoQuality,
                onChanged: (v) =>
                    settings.update(app.copyWith(autoQuality: v)),
              ),
              const Divider(),
              _SectionHeader('Appearance'),
              _RadioGroup<ThemeSetting>(
                title: 'Theme',
                icon: Icons.brightness_6,
                options: ThemeSetting.values,
                value: app.themeMode,
                label: (t) => t.label,
                onChanged: (v) =>
                    settings.update(app.copyWith(themeMode: v!)),
              ),
              const Divider(),
              _SectionHeader('Startup & privacy'),
              SwitchListTile(
                secondary: const Icon(Icons.radar),
                title: const Text('Auto-discover on launch'),
                subtitle: const Text(
                    'Start listening for PCs as soon as the app opens.'),
                value: app.autoStart,
                onChanged: (v) =>
                    settings.update(app.copyWith(autoStart: v)),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.content_paste),
                title: const Text('Clipboard sync'),
                subtitle: const Text(
                    'Share clipboard between phone and PC while connected.'),
                value: app.clipboardSync,
                onChanged: (v) async {
                  await settings.update(app.copyWith(clipboardSync: v));
                  await services.bridge.setClipboardWatcher(v);
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.shield_outlined),
                title: const Text('Send crash diagnostics'),
                subtitle: const Text(
                    'Help improve MirrorLink. No personal data is sent.'),
                value: app.allowDiagnostics,
                onChanged: (v) =>
                    settings.update(app.copyWith(allowDiagnostics: v)),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.smartphone),
                title: const Text('Device nickname'),
                subtitle: Text(app.deviceNickname.isEmpty
                    ? 'Shown on the PC dashboard'
                    : app.deviceNickname),
                trailing: const Icon(Icons.edit),
                onTap: () => _editNickname(context, settings),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _editNickname(
      BuildContext context, dynamic settings) async {
    final controller = TextEditingController(text: settings.app.deviceNickname);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Device nickname'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: 'e.g. Pixel 8 Pro'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null) {
      await settings.update(settings.app.copyWith(deviceNickname: result));
    }
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
      ),
    );
  }
}

class _RadioGroup<T> extends StatelessWidget {
  const _RadioGroup({
    required this.title,
    required this.icon,
    required this.options,
    required this.value,
    required this.label,
    required this.onChanged,
  });

  final String title;
  final IconData icon;
  final List<T> options;
  final T value;
  final String Function(T) label;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: options
          .map((option) => RadioListTile<T>(
                value: option,
                groupValue: value,
                onChanged: onChanged,
                secondary: option == options.first
                    ? Icon(icon)
                    : null,
                title: Text(label(option)),
              ))
          .toList(),
    );
  }
}
