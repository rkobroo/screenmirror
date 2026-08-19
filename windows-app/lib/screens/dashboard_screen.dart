import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../models/device.dart';
import '../services/session_manager.dart';
import 'settings_screen.dart';
import 'viewer_screen.dart';
import '../widgets/media_viewer.dart';

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
              _ChatCard(services: services),
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
              if (session.error.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline,
                          color: theme.colorScheme.onErrorContainer),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          session.error,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
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

class _ChatCard extends StatelessWidget {
  const _ChatCard({required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.chat_bubble_outline, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Chat',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const Spacer(),
                AnimatedBuilder(
                  animation: services.session,
                  builder: (context, _) {
                    final n = services.session.messages.length;
                    return n > 0
                        ? Text('$n messages',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant))
                        : const SizedBox.shrink();
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.fullscreen, size: 20),
                  tooltip: 'Expand chat',
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => _ChatFullScreenPage(services: services)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _ChatPanel(services: services),
          ],
        ),
      ),
    );
  }
}

class _ChatPanel extends StatefulWidget {
  const _ChatPanel({required this.services, this.fullscreen = false});

  final AppServices services;
  final bool fullscreen;

  @override
  State<_ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<_ChatPanel> {
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
    widget.services.session.sendChatMessage(text);
    _textCtrl.clear();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  Future<void> _pickAndSendMedia() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'mp4', 'mkv', 'mov', 'avi', 'webm'],
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    final name = result.files.single.name;
    final ext = name.split('.').last.toLowerCase();
    if (['mp4', 'mkv', 'mov', 'avi', 'webm'].contains(ext)) {
      widget.services.session.sendVideoMessage(path, name);
    } else {
      widget.services.session.sendPhotoMessage(path, name);
    }
  }

  void _openFile(String path) {
    if (Platform.isWindows) {
      Process.run('cmd', ['/c', 'start', '', path]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: widget.services.session,
      builder: (context, _) {
        final messages = widget.services.session.messages;
        final connected = widget.services.session.device != null;
        final listWidget = messages.isEmpty
            ? const Center(
                child: Text(
                  'No messages yet. Say hello!',
                  style: TextStyle(color: Colors.white38, fontSize: 13),
                ),
              )
            : ListView.builder(
                controller: _scrollCtrl,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final msg = messages[index];
                  return _DashboardChatBubble(
                    msg: msg,
                    onOpenFile: _openFile,
                  );
                },
              );
        final listArea = widget.fullscreen
            ? Expanded(child: listWidget)
            : Container(
                height: 220,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withAlpha(80),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: listWidget,
              );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!connected)
              Text('Connect a phone to start chatting.',
                  style: theme.textTheme.bodyMedium)
            else ...[
              listArea,
              const SizedBox(height: 10),
              Row(
                children: [
                  IconButton(
                    onPressed: _pickAndSendMedia,
                    icon: const Icon(Icons.add_photo_alternate, size: 20),
                    tooltip: 'Send photo or video',
                  ),
                  Expanded(
                    child: TextField(
                      controller: _textCtrl,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'Type a message...',
                        hintStyle: TextStyle(color: Colors.white38, fontSize: 13),
                        filled: true,
                        fillColor: theme.colorScheme.surfaceContainerHighest.withAlpha(120),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                    tooltip: 'Send',
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class _ChatFullScreenPage extends StatelessWidget {
  const _ChatFullScreenPage({required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chat'),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: _ChatPanel(services: services, fullscreen: true),
        ),
      ),
    );
  }
}

class _DashboardChatBubble extends StatelessWidget {
  const _DashboardChatBubble({required this.msg, required this.onOpenFile});

  final ChatMessage msg;
  final void Function(String path) onOpenFile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final align = msg.fromMe ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bgColor = msg.fromMe
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final textColor = msg.fromMe
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;
    final radius = msg.fromMe
        ? const BorderRadius.only(
            topLeft: Radius.circular(14),
            topRight: Radius.circular(14),
            bottomLeft: Radius.circular(14),
            bottomRight: Radius.circular(4),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(14),
            topRight: Radius.circular(14),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(14),
          );

    final timeStr =
        '${msg.time.hour.toString().padLeft(2, '0')}:${msg.time.minute.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: align,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            constraints: const BoxConstraints(maxWidth: 320),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: radius,
            ),
            child: _buildContent(context, textColor),
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '${msg.fromMe ? "You" : "Phone"} · $timeStr',
              style: TextStyle(color: Colors.white38, fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context, Color textColor) {
    if (msg.type == ChatMessageType.text && !msg.text.startsWith('[Photo:') && !msg.text.startsWith('[Video:')) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            child: SelectableText(
              msg.text,
              style: TextStyle(color: textColor, fontSize: 13),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: msg.text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Copied to clipboard'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(Icons.copy, size: 14, color: textColor.withAlpha(120)),
            ),
          ),
        ],
      );
    }

    final isImage = msg.type == ChatMessageType.image ||
        (msg.fileName.isNotEmpty && _isImageExt(msg.fileName)) ||
        (msg.text.startsWith('[Photo:'));

    final isVideo = msg.type == ChatMessageType.video ||
        (msg.fileName.isNotEmpty && _isVideoExt(msg.fileName)) ||
        (msg.text.startsWith('[Video:'));

    if (isImage && msg.filePath.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: GestureDetector(
              onTap: () => _openMedia(context, msg.filePath, false),
              child: Image.file(
                File(msg.filePath),
                width: 200,
                height: 130,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  width: 200,
                  height: 60,
                  color: Colors.white12,
                  child: const Icon(Icons.broken_image, color: Colors.white38),
                ),
              ),
            ),
          ),
        ],
      );
    }

    if (isVideo && msg.filePath.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () => _openMedia(context, msg.filePath, true),
            child: Container(
              width: 200,
              height: 130,
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Stack(
                alignment: Alignment.center,
                children: [
                  Icon(Icons.play_circle_filled, color: Colors.white, size: 48),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_fileIcon(msg.fileName), color: textColor.withAlpha(180), size: 18),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                msg.fileName.isNotEmpty ? msg.fileName : msg.text,
                style: TextStyle(color: textColor, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (msg.fileSize > 0) ...[
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: msg.fraction,
            backgroundColor: Colors.white24,
            color: msg.fileDone ? Colors.greenAccent : Colors.blueAccent,
            minHeight: 3,
          ),
          const SizedBox(height: 2),
          Text(
            msg.fileDone
                ? 'Done · ${_fmtSize(msg.fileSize)}'
                : '${_fmtSize(msg.fileProgress)} / ${_fmtSize(msg.fileSize)}',
            style: TextStyle(color: textColor.withAlpha(140), fontSize: 10),
          ),
        ],
        if (msg.fileDone && msg.filePath.isNotEmpty)
          GestureDetector(
            onTap: () => _openFile(msg.filePath),
            child: const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'Open file',
                style: TextStyle(
                  color: Colors.blueAccent,
                  fontSize: 11,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _openFile(String path) {
    if (Platform.isWindows) {
      Process.run('cmd', ['/c', 'start', '', path]);
    }
  }

  void _openMedia(BuildContext context, String path, bool isVideo) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MediaViewerScreen(filePath: path, isVideo: isVideo),
      ),
    );
  }

  static bool _isImageExt(String name) {
    final ext = name.split('.').last.toLowerCase();
    return {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'}.contains(ext);
  }

  static bool _isVideoExt(String name) {
    final ext = name.split('.').last.toLowerCase();
    return {'mp4', 'mkv', 'avi', 'mov', 'webm'}.contains(ext);
  }

  static IconData _fileIcon(String name) {
    final ext = name.split('.').last.toLowerCase();
    if ({'jpg', 'jpeg', 'png', 'gif', 'webp'}.contains(ext)) return Icons.image;
    if ({'mp4', 'mkv', 'avi', 'mov', 'webm'}.contains(ext)) return Icons.video_file;
    if ({'mp3', 'wav', 'ogg', 'aac'}.contains(ext)) return Icons.audio_file;
    if (ext == 'pdf') return Icons.picture_as_pdf;
    if (ext == 'apk') return Icons.android;
    return Icons.insert_drive_file;
  }

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
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
