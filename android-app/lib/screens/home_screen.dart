import 'package:flutter/material.dart' hide ConnectionState;

import '../app_services.dart';
import '../services/connection_controller.dart';
import '../services/file_transfer_service.dart';
import 'pairing_screen.dart';
import 'settings_screen.dart';

/// Landing screen: device info card, connection status, and primary actions.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  static const route = '/home';

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Map<String, dynamic> _deviceInfo = const {};

  @override
  void initState() {
    super.initState();
    _loadDeviceInfo();
  }

  Future<void> _loadDeviceInfo() async {
    try {
      final info = await ServicesScope.of(context).bridge.getDeviceInfo();
      if (mounted) setState(() => _deviceInfo = info);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context);
    final controller = services.controller;

    return Scaffold(
      appBar: AppBar(
        title: const Text('MirrorLink'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.pushNamed(context, SettingsScreen.route),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _DeviceCard(
                name: _deviceInfo['name'] as String? ?? 'Android phone',
                version:
                    'Android ${_deviceInfo['androidVersion'] ?? '—'} (SDK ${_deviceInfo['sdk'] ?? '—'})',
                connectedTo: controller.connectedTo?.name,
                state: controller.state,
                fps: controller.fps,
                bps: controller.bps,
              ),
              const SizedBox(height: 16),
              if (controller.state == ConnectionState.error) ...[
                _ErrorBanner(message: controller.lastError),
                const SizedBox(height: 16),
              ],
              if (controller.state == ConnectionState.streaming) ...[
                _AccessibilityBanner(services: services),
                const SizedBox(height: 12),
              ],
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                ),
                icon: const Icon(Icons.screen_share),
                label: const Text('Start Mirroring'),
                onPressed: controller.state == ConnectionState.streaming
                    ? () => controller.startMirroring()
                    : null,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                ),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Pair Device'),
                onPressed: () async {
                  await Navigator.pushNamed(context, PairingScreen.route);
                },
              ),
              const SizedBox(height: 12),
              if (controller.state != ConnectionState.idle &&
                  controller.state != ConnectionState.discovering)
                TextButton.icon(
                  icon: const Icon(Icons.link_off),
                  label: const Text('Disconnect'),
                  onPressed: () => controller.disconnect(),
                ),
              const SizedBox(height: 24),
              _FileTransfersCard(services: services),
            ],
          );
        },
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.name,
    required this.version,
    required this.state,
    this.connectedTo,
    this.fps = 0,
    this.bps = 0,
  });

  final String name;
  final String version;
  final ConnectionState state;
  final String? connectedTo;
  final int fps;
  final int bps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color) = switch (state) {
      ConnectionState.idle => ('Disconnected', theme.colorScheme.outline),
      ConnectionState.discovering => ('Searching…', theme.colorScheme.tertiary),
      ConnectionState.pairing => ('Pairing…', theme.colorScheme.tertiary),
      ConnectionState.negotiating => ('Negotiating…', theme.colorScheme.tertiary),
      ConnectionState.streaming => ('Streaming', theme.colorScheme.primary),
      ConnectionState.disconnected => ('Disconnected', theme.colorScheme.outline),
      ConnectionState.error => ('Error', theme.colorScheme.error),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.smartphone, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      Text(version, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                Chip(
                  avatar: Icon(Icons.circle, size: 12, color: color),
                  label: Text(label),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            if (connectedTo != null) ...[
              const Divider(height: 24),
              Text('Mirroring to $connectedTo',
                  style: theme.textTheme.bodyMedium),
              const SizedBox(height: 4),
              Text('$fps fps · ${(bps / 1000).round()} kbps',
                  style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: ListTile(
        leading: const Icon(Icons.error_outline),
        title: Text(message),
      ),
    );
  }
}

/// Reminds the user to enable the accessibility service for remote input.
class _AccessibilityBanner extends StatefulWidget {
  const _AccessibilityBanner({required this.services});

  final AppServices services;

  @override
  State<_AccessibilityBanner> createState() => _AccessibilityBannerState();
}

class _AccessibilityBannerState extends State<_AccessibilityBanner> {
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final enabled =
        await widget.services.bridge.isAccessibilityEnabled();
    if (mounted) setState(() => _enabled = enabled);
  }

  @override
  Widget build(BuildContext context) {
    if (_enabled) return const SizedBox.shrink();
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: ListTile(
        leading: const Icon(Icons.accessibility_new),
        title: const Text('Enable remote control'),
        subtitle: const Text(
            'Allow the MirrorLink accessibility service so the PC can tap, '
            'type, and swipe your phone.'),
        trailing: TextButton(
          onPressed: () async {
            await widget.services.bridge.openAccessibilitySettings();
            await Future.delayed(const Duration(seconds: 1));
            await _check();
          },
          child: const Text('Enable'),
        ),
      ),
    );
  }
}

class _FileTransfersCard extends StatelessWidget {
  const _FileTransfersCard({required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: services.files,
      builder: (context, _) {
        final transfers = services.files.transfers;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.swap_vert, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Text('File transfers',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () => services.files.sendFileToPc(),
                      icon: const Icon(Icons.upload_file, size: 18),
                      label: const Text('Send to PC'),
                    ),
                  ],
                ),
                if (transfers.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('No transfers yet.',
                        style: theme.textTheme.bodySmall),
                  )
                else
                  ...transfers.reversed.take(5).map((t) => Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(t.name,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              t.status == TransferStatus.done
                                  ? 'Done'
                                  : '${(t.fraction * 100).round()}%',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      )),
              ],
            ),
          ),
        );
      },
    );
  }
}
