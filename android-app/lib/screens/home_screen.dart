import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';

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

  Future<void> _startMirroring(
      BuildContext context, AppServices services) async {
    final enabled = await services.bridge.isAccessibilityEnabled();
    if (!enabled && context.mounted) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.accessibility_new, size: 40),
          title: const Text('Enable remote control?'),
          content: const Text(
              'The accessibility service is needed so the PC can tap, '
              'swipe, and type on your phone.\n\n'
              'You can still mirror without it — remote control just '
              'won\'t work until you enable it.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Skip'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Enable'),
            ),
          ],
        ),
      );
      if (go == true) {
        await services.bridge.openAccessibilitySettings();
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    if (context.mounted) {
      services.controller.startMirroring();
    }
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
              _AccessibilityBanner(services: services),
              const SizedBox(height: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                ),
                icon: Icon(
                  controller.state == ConnectionState.streaming
                      ? Icons.stop
                      : Icons.screen_share,
                ),
                label: Text(
                  controller.state == ConnectionState.streaming
                      ? 'Stop Mirroring'
                      : 'Start Mirroring',
                ),
                onPressed: controller.state == ConnectionState.streaming
                    ? () => controller.disconnect()
                    : () => _startMirroring(context, services),
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
              _ChatCard(services: services),
              const SizedBox(height: 16),
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

class _ChatCard extends StatefulWidget {
  const _ChatCard({required this.services});

  final AppServices services;

  @override
  State<_ChatCard> createState() => _ChatCardState();
}

class _ChatCardState extends State<_ChatCard> {
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _send() {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    widget.services.controller.sendChatMessage(text);
    _textCtrl.clear();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  Future<void> _pickAndSendImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowCompression: false,
    );
    if (result == null || result.files.isEmpty) return;
    final f = result.files.single;
    final path = f.path;
    if (path == null) return;
    widget.services.controller.sendPhotoMessage(path, f.name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.services.controller;
    final messages = controller.messages;
    final connected = controller.state == ConnectionState.streaming ||
        controller.state == ConnectionState.negotiating ||
        controller.state == ConnectionState.pairing;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.chat_bubble_outline, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Chat',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const Spacer(),
                if (messages.isNotEmpty)
                  Text('${messages.length}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 8),
            if (messages.isEmpty && !connected)
              Text('Connect to PC to chat.',
                  style: theme.textTheme.bodySmall)
            else ...[
              Container(
                constraints: const BoxConstraints(minHeight: 120, maxHeight: 340),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withAlpha(80),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: messages.isEmpty
                    ? const Center(
                        child: Text(
                          'No messages yet.',
                          style: TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        itemCount: messages.length,
                        itemBuilder: (context, index) {
                          final msg = messages[index];
                          final isMe = msg.fromMe;
                          final timeStr =
                              '${msg.time.hour.toString().padLeft(2, '0')}:${msg.time.minute.toString().padLeft(2, '0')}';
                          return GestureDetector(
                            onLongPress: () {
                              Clipboard.setData(ClipboardData(text: msg.text));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Copied to clipboard'),
                                  duration: Duration(seconds: 1),
                                ),
                              );
                            },
                            child: Align(
                              alignment: isMe
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: Container(
                                margin:
                                    const EdgeInsets.symmetric(vertical: 2),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                                constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.of(context).size.width * 0.7,
                                ),
                                decoration: BoxDecoration(
                                  color: isMe
                                      ? theme.colorScheme.primary
                                      : theme
                                          .colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Column(
                                  crossAxisAlignment: isMe
                                      ? CrossAxisAlignment.end
                                      : CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (msg.type == ChatMessageType.image &&
                                        msg.filePath.isNotEmpty)
                                      ClipRRect(
                                        borderRadius:
                                            BorderRadius.circular(8),
                                        child: Image.file(
                                          File(msg.filePath),
                                          width: 200,
                                          height: 130,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) =>
                                              Container(
                                            width: 200,
                                            height: 60,
                                            color: Colors.white12,
                                            child: const Icon(
                                                Icons.broken_image,
                                                color: Colors.white38),
                                          ),
                                        ),
                                      ),
                                    if (msg.type == ChatMessageType.image &&
                                        msg.filePath.isNotEmpty)
                                      const SizedBox(height: 4),
                                    Text(
                                      msg.type == ChatMessageType.image
                                          ? msg.fileName
                                          : msg.text,
                                      style: TextStyle(
                                        color: isMe
                                            ? theme.colorScheme.onPrimary
                                            : theme.colorScheme.onSurface,
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${isMe ? "You" : "PC"} · $timeStr',
                                      style: TextStyle(
                                        color: isMe
                                            ? theme.colorScheme.onPrimary
                                                .withAlpha(140)
                                            : Colors.white38,
                                        fontSize: 9,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 8),
              if (connected) ...[
                Row(
                  children: [
                    IconButton(
                      onPressed: _pickAndSendImage,
                      icon: const Icon(Icons.attach_file, size: 20),
                      tooltip: 'Attach photo',
                    ),
                    Expanded(
                      child: TextField(
                        controller: _textCtrl,
                        style: const TextStyle(fontSize: 13),
                        decoration: InputDecoration(
                          hintText: 'Type a message...',
                          hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                          filled: true,
                          fillColor: theme.colorScheme.surfaceContainerHighest.withAlpha(120),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _send,
                      icon: Icon(Icons.send, color: theme.colorScheme.primary),
                    ),
                  ],
                ),
              ],
            ],
          ],
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
