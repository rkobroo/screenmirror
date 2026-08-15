import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../models/app_settings.dart';

/// Desktop settings: language, notifications, updates, save location.
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
              const _SectionHeader('General'),
              ListTile(
                leading: const Icon(Icons.language),
                title: const Text('Language'),
                subtitle: const Text('English (current)'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _notImplemented(context),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.notifications_active_outlined),
                title: const Text('Notifications'),
                subtitle: const Text('Show toasts when a phone connects or a '
                    'transfer finishes.'),
                value: app.notifications,
                onChanged: (v) => settings.update(app.copyWith(notifications: v)),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.system_update),
                title: const Text('Check for updates'),
                subtitle: const Text('Poll the GitHub releases API on startup.'),
                value: app.checkUpdates,
                onChanged: (v) => settings.update(app.copyWith(checkUpdates: v)),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.picture_in_picture_alt),
                title: const Text('Minimize dashboard on connect'),
                subtitle: const Text('Auto-minimize this window when a viewer '
                    'is opened.'),
                value: app.autoMinimizeOnConnect,
                onChanged: (v) =>
                    settings.update(app.copyWith(autoMinimizeOnConnect: v)),
              ),
              const Divider(),
              const _SectionHeader('Transfers'),
              ListTile(
                leading: const Icon(Icons.folder_open),
                title: const Text('Save received files to'),
                subtitle: Text(app.saveDirectory.isEmpty
                    ? 'Documents\\MirrorLink (default)'
                    : app.saveDirectory),
                trailing: const Icon(Icons.folder),
                onTap: () async {
                  final dir = await FilePicker.platform.getDirectoryPath();
                  if (dir != null) {
                    await settings.update(app.copyWith(saveDirectory: dir));
                  }
                },
              ),
              const Divider(),
              const _SectionHeader('About'),
              const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('MirrorLink for Windows'),
                subtitle: Text('Version 1.0.0 · MIT licensed · No accounts, '
                    'no tracking, no cloud servers.'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _notImplemented(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('English is the only language right now.')),
    );
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
