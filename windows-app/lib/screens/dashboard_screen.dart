import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../models/device.dart';
import 'settings_screen.dart';
import 'viewer_screen.dart';

/// Main window: pairing code, live session, transfers, and history.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  static const route = '/';

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('MirrorLink'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh discovery & pairing code',
            onPressed: () async {
              await services.refreshDiscovery();
              if (mounted) setState(() {});
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () =>
                Navigator.pushNamed(context, SettingsScreen.route),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: services.session,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _PairingCard(
                services: services,
                onRefresh: () async {
                  await services.refreshDiscovery();
                  setState(() {});
                },
              ),
              const SizedBox(height: 16),
              _SessionCard(services: services),
              const SizedBox(height: 16),
              _TransfersCard(services: services),
              const SizedBox(height: 16),
              _HistoryCard(services: services),
            ],
          );
        },
      ),
    );
  }
}

class _PairingCard extends StatelessWidget {
  const _PairingCard({required this.services, required this.onRefresh});

  final AppServices services;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = services.signaling.pairingCode;
    final remaining = services.signaling.codeExpiry.difference(DateTime.now());
    final seconds = remaining.inSeconds.clamp(0, 120);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.wifi_tethering, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Pair a phone',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'On your Android phone open MirrorLink, tap Pair device and '
              'enter this code (${services.pcName}):',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      code,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: 8,
                        color: theme.colorScheme.primary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'New code',
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Code expires in $seconds s · one-time use',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Text(
              'Scanning the QR code shown here is coming in a future release; '
              'the phone can also find this PC automatically.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = services.session;
    final device = session.device;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.phone_android, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Device',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 12),
            if (device == null)
              Text('No phone connected. Pair using the code above.',
                  style: theme.textTheme.bodyMedium)
            else ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Icon(Icons.smartphone,
                      color: theme.colorScheme.onPrimaryContainer),
                ),
                title: Text(device.nickname.isNotEmpty
                    ? device.nickname
                    : device.name),
                subtitle: Text('${device.ip} · '
                    '${session.isStreaming ? '${session.fps} fps · ${(session.bps / 1000).round()} kbps' : _statusLabel(device.status)}'),
                trailing: session.isStreaming
                    ? FilledButton(
                        onPressed: () => Navigator.pushNamed(
                            context, ViewerScreen.route),
                        child: const Text('Open Viewer'),
                      )
                    : null,
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _statusLabel(DeviceStatus status) => switch (status) {
        DeviceStatus.paired => 'Paired',
        DeviceStatus.connected => 'Connected',
        DeviceStatus.streaming => 'Streaming',
        DeviceStatus.disconnected => 'Disconnected',
      };
}

class _TransfersCard extends StatelessWidget {
  const _TransfersCard({required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final transfers = services.session.transfers;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.swap_vert, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('File transfers',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 8),
            if (transfers.isEmpty)
              Text('No transfers yet. Send files from the viewer window.',
                  style: theme.textTheme.bodyMedium)
            else
              ...transfers.take(6).map((t) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              t.direction == 'to'
                                  ? Icons.arrow_downward
                                  : Icons.arrow_upward,
                              size: 16,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(t.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                            ),
                            Text(
                              t.done
                                  ? 'Done'
                                  : '${(t.fraction * 100).round()}%',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                        if (!t.done)
                          LinearProgressIndicator(value: t.fraction),
                      ],
                    ),
                  )),
          ],
        ),
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final history = services.settings.history;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Connection history',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 8),
            if (history.isEmpty)
              Text('No previous connections.',
                  style: theme.textTheme.bodyMedium)
            else
              ...history.take(8).map((record) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: const Icon(Icons.schedule),
                    title: Text(record.name),
                    subtitle: Text(
                        '${record.ip} · ${record.connectedAt.toLocal().toString().substring(0, 16)}'),
                    trailing: Text(
                      '${record.duration.inMinutes} min',
                      style: theme.textTheme.bodySmall,
                    ),
                  )),
          ],
        ),
      ),
    );
  }
}
