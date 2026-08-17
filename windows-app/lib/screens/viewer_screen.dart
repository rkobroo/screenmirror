import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import '../app_services.dart';
import '../services/mjpeg_writer.dart';
import '../services/session_manager.dart';

/// Remote viewer: live phone screen plus remote control (mouse, keyboard,
/// system buttons), screenshot, and screen recording.
class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key});

  static const route = '/viewer';

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  final _boundaryKey = GlobalKey();
  Offset? _dragStart;
  Offset? _lastDrag;

  bool _recording = false;
  bool _capturing = false;
  MjpegWriter? _writer;
  Timer? _recTimer;
  bool _fullscreen = false;
  bool _showChat = false;

  AppServices? _services;

  // ---- touch fix: track video & container dimensions ----
  Size _containerSize = Size.zero;

  // ---- text input bar ----
  final _textController = TextEditingController();
  final _textFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _stopRecording();
    _textController.dispose();
    _textFocusNode.dispose();
    super.dispose();
  }

  // ---- touch input: normalize against actual video render rect ----

  /// Where the video actually renders inside the container (objectFit: contain).
  Rect _videoRect(Size container, Size videoFrame) {
    if (videoFrame.isEmpty || container.isEmpty) return Offset.zero & container;
    final containerAspect = container.width / container.height;
    final videoAspect = videoFrame.width / videoFrame.height;
    double rw, rh;
    if (videoAspect > containerAspect) {
      rw = container.width;
      rh = container.width / videoAspect;
    } else {
      rh = container.height;
      rw = container.height * videoAspect;
    }
    return Rect.fromLTWH(
      (container.width - rw) / 2,
      (container.height - rh) / 2,
      rw,
      rh,
    );
  }

  Offset _normalize(Offset local) {
    final videoFrame = _services?.session.captureSize ?? Size.zero;
    final vr = _videoRect(_containerSize, videoFrame);
    if (vr.isEmpty) return Offset.zero;
    return Offset(
      ((local.dx - vr.left) / vr.width).clamp(0.0, 1.0),
      ((local.dy - vr.top) / vr.height).clamp(0.0, 1.0),
    );
  }

  void _onPointerDown(PointerDownEvent e) {
    final services = _services!;
    if (!services.session.isStreaming) return;
    final p = _normalize(e.localPosition);
    _dragStart = p;
    _lastDrag = p;
    services.session.sendTouch(p.dx, p.dy, 0);
  }

  void _onPointerMove(PointerMoveEvent e) {
    final services = _services!;
    if (!services.session.isStreaming || _dragStart == null) return;
    final p = _normalize(e.localPosition);
    final from = _lastDrag ?? p;
    if ((from - p).distance > 0.02) {
      services.session.sendSwipe(
        [
          [from.dx, from.dy],
          [p.dx, p.dy],
        ],
        40,
      );
      _lastDrag = p;
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    final services = _services!;
    if (!services.session.isStreaming) return;
    final p = _normalize(e.localPosition);
    final start = _dragStart ?? p;
    final moved = (start - p).distance > 0.05;
    if (!moved) {
      services.session.sendTouch(p.dx, p.dy, 2);
    }
    _dragStart = null;
    _lastDrag = null;
  }

  // ---- input: keyboard -------------------------------------------------------

  bool _onKey(KeyEvent event) {
    final services = _services;
    if (services == null || !services.session.isStreaming) return false;
    if (event is! KeyDownEvent) return false;

    // Don't forward keys when the text input has focus.
    if (_textFocusNode.hasFocus) return false;

    final session = services.session;
    final logical = event.logicalKey;

    if (HardwareKeyboard.instance.isControlPressed) {
      final key = logical;
      if (key == LogicalKeyboardKey.keyB) {
        session.sendSysButton('back');
        return true;
      }
      if (key == LogicalKeyboardKey.keyH) {
        session.sendSysButton('home');
        return true;
      }
      if (key == LogicalKeyboardKey.keyJ) {
        session.sendSysButton('recents');
        return true;
      }
      if (key == LogicalKeyboardKey.keyS) {
        _takeScreenshot();
        return true;
      }
      if (key == LogicalKeyboardKey.keyR) {
        _toggleRecording();
        return true;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        session.sendVolume('up');
        return true;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        session.sendVolume('down');
        return true;
      }
      if (key == LogicalKeyboardKey.space) {
        session.sendMedia('play');
        return true;
      }
      // Don't forward any Ctrl combos as text.
      return true;
    }

    final code = _androidKeyCode(logical);
    if (code != null) {
      session.sendKey(code, 0);
      return true;
    }

    final character = event.character;
    if (character != null && character.isNotEmpty) {
      session.sendText(character);
      return true;
    }
    return false;
  }

  int? _androidKeyCode(LogicalKeyboardKey key) {
    final map = <LogicalKeyboardKey, int>{
      LogicalKeyboardKey.enter: 66,
      LogicalKeyboardKey.backspace: 67,
      LogicalKeyboardKey.tab: 61,
      LogicalKeyboardKey.escape: 4, // BACK
      LogicalKeyboardKey.delete: 112,
      LogicalKeyboardKey.space: 62,
      LogicalKeyboardKey.arrowUp: 19,
      LogicalKeyboardKey.arrowDown: 20,
      LogicalKeyboardKey.arrowLeft: 21,
      LogicalKeyboardKey.arrowRight: 22,
      LogicalKeyboardKey.home: 3,
      LogicalKeyboardKey.end: 123,
      LogicalKeyboardKey.pageUp: 92,
      LogicalKeyboardKey.pageDown: 93,
      LogicalKeyboardKey.metaLeft: 0, // not mapped
    };
    return map[key];
  }

  // ---- capture ------------------------------------------------------------------

  Future<ui.Image?> _capture() async {
    final boundary = _boundaryKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary == null) return null;
    try {
      return await boundary.toImage(pixelRatio: 1.0);
    } catch (_) {
      return null;
    }
  }

  Future<void> _takeScreenshot() async {
    final image = await _capture();
    if (image == null) return;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) return;

    final dir = await _mediaDir();
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final file = File('${dir.path}\\screenshot_$stamp.png');
    await file.writeAsBytes(data.buffer.asUint8List());
    _notify('Screenshot saved: ${file.path}');
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      _stopRecording();
      return;
    }
    final boundary = _boundaryKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary == null) return;
    final size = boundary.size;

    final dir = await _mediaDir();
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final path = '${dir.path}\\recording_$stamp.avi';
    _writer = MjpegWriter(path, size.width.round(), size.height.round(), 10);

    _recTimer = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      if (_capturing) return;
      _capturing = true;
      try {
        final image = await _capture();
        if (image == null) return;
        final width = image.width, height = image.height;
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
        if (data == null) return;
        final frame = img.Image.fromBytes(
          width: width,
          height: height,
          bytes: data.buffer,
          order: img.ChannelOrder.rgba,
          numChannels: 4,
        );
        final jpeg = img.encodeJpg(frame, quality: 70);
        _writer?.addJpeg(jpeg);
      } finally {
        _capturing = false;
      }
    });

    setState(() => _recording = true);
    _notify('Recording started → $path');
  }

  Future<void> _stopRecording() async {
    _recTimer?.cancel();
    _recTimer = null;
    final writer = _writer;
    _writer = null;
    if (writer != null) {
      await writer.close();
    }
    if (mounted) {
      setState(() => _recording = false);
      _notify('Recording finished.');
    }
  }

  Future<Directory> _mediaDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}\\MirrorLink');
    await dir.create(recursive: true);
    return dir;
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ---- other actions ----------------------------------------------------------

  Future<void> _sendFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    final name = path.split(Platform.pathSeparator).last;
    _notify('Sending: $name…');
    await _services!.session.sendFileToPhone(path);
    _notify('Sent: $name');
  }

  Future<void> _toggleFullscreen() async {
    final next = !_fullscreen;
    await windowManager.setFullScreen(next);
    if (mounted) setState(() => _fullscreen = next);
  }

  void _sendTextMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty || _services == null) return;
    _services!.session.sendChatMessage(text);
    _textController.clear();
  }

  Future<void> _attachAndSend() async {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    await _services!.session.sendFileToPhone(path);
  }

  void _openFile(String path) {
    try {
      Process.run('cmd', ['/c', 'start', '', path]);
    } catch (_) {}
  }

  // ---- build --------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context);
    _services = services;
    final session = services.session;

    // Wire up clipboard/file notifications (safe to reassign).
    session.onIncomingClipboard = (text) {
      _notify('Clipboard received: ${text.length > 50 ? '${text.substring(0, 50)}...' : text}');
    };
    session.onClipboardSent = (text) {
      _notify('Clipboard sent: ${text.length > 50 ? '${text.substring(0, 50)}...' : text}');
    };
    session.onFileReceived = (name, path) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('File received: $name'),
        action: SnackBarAction(
          label: 'Open',
          textColor: Colors.blueAccent,
          onPressed: () => _openFile(path),
        ),
        duration: const Duration(seconds: 5),
      ));
    };

    return Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedBuilder(
        animation: session,
        builder: (context, _) {
          final streaming = session.isStreaming;

          return Column(
            children: [
              // Main area: video + optional chat panel
              Expanded(
                child: Row(
                  children: [
                    // Video area
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                _containerSize = Size(
                                  constraints.maxWidth,
                                  constraints.maxHeight,
                                );
                                return Listener(
                                  onPointerDown: _onPointerDown,
                                  onPointerMove: _onPointerMove,
                                  onPointerUp: _onPointerUp,
                                  onPointerCancel: (_) => _dragStart = null,
                                  onPointerSignal: (e) {
                                    if (e is PointerScrollEvent && session.isStreaming) {
                                      session.sendScroll(e.scrollDelta.dx, e.scrollDelta.dy);
                                    }
                                  },
                                  child: RepaintBoundary(
                                    key: _boundaryKey,
                                    child: streaming
                                        ? _VideoView(session: session)
                                        : _NoStreamPlaceholder(error: session.error),
                                  ),
                                );
                              },
                            ),
                          ),
                          _Toolbar(
                            streaming: streaming,
                            recording: _recording,
                            fullscreen: _fullscreen,
                            chatOpen: _showChat,
                            onBack: () => session.sendSysButton('back'),
                            onHome: () => session.sendSysButton('home'),
                            onRecents: () => session.sendSysButton('recents'),
                            onVolumeUp: () => session.sendVolume('up'),
                            onVolumeDown: () => session.sendVolume('down'),
                            onPlayPause: () => session.sendMedia('play'),
                            onScreenshot: _takeScreenshot,
                            onRecord: _toggleRecording,
                            onSendFile: _sendFile,
                            onFullscreen: _toggleFullscreen,
                            onChat: () => setState(() => _showChat = !_showChat),
                            onClose: () => Navigator.of(context).pop(),
                          ),
                          if (streaming)
                            Positioned(
                              left: 8,
                              bottom: 8,
                              child: Text(
                                '${session.fps} fps · ${(session.bps / 1000).round()} kbps',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          if (streaming && session.transfers.isNotEmpty)
                            Positioned(
                              right: 8,
                              bottom: 8,
                              child: _TransferOverlay(transfers: session.transfers),
                            ),
                        ],
                      ),
                    ),
                    // Chat side panel
                    if (_showChat)
                      SizedBox(
                        width: 320,
                        child: _ChatPanel(
                          messages: session.messages,
                          onOpenFile: _openFile,
                        ),
                      ),
                  ],
                ),
              ),
              // Text input bar at the bottom
              if (streaming)
                _TextInputBar(
                  controller: _textController,
                  focusNode: _textFocusNode,
                  onSend: _sendTextMessage,
                  onAttach: _attachAndSend,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _VideoView extends StatelessWidget {
  const _VideoView({required this.session});

  final SessionManager session;

  @override
  Widget build(BuildContext context) {
    return RTCVideoView(
      session.renderer,
      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
    );
  }
}

class _NoStreamPlaceholder extends StatelessWidget {
  const _NoStreamPlaceholder({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.monitor, color: Colors.white24, size: 64),
          const SizedBox(height: 16),
          Text(
            error.isNotEmpty ? error : 'Waiting for the phone to stream…',
            style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Shows active transfer progress in the bottom-right of the viewer.
class _TransferOverlay extends StatelessWidget {
  const _TransferOverlay({required this.transfers});

  final List<Transfer> transfers;

  @override
  Widget build(BuildContext context) {
    final active = transfers.where((t) => !t.done).toList();
    if (active.isEmpty) return const SizedBox.shrink();
    final t = active.first;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            '${t.direction == "to" ? "Sending" : "Receiving"}: ${t.name}',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: 160,
            child: LinearProgressIndicator(
              value: t.fraction,
              backgroundColor: Colors.white24,
              color: Colors.blueAccent,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${(t.fraction * 100).round()}%',
            style: const TextStyle(color: Colors.white54, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

/// Bottom text input bar for sending text to the phone.
class _TextInputBar extends StatelessWidget {
  const _TextInputBar({
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.onAttach,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final VoidCallback onAttach;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey[900],
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.attach_file, color: Colors.white54, size: 20),
            tooltip: 'Send file',
            onPressed: onAttach,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Type message or text to send…',
                hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
              ),
              onSubmitted: (_) => onSend(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.send, color: Colors.blueAccent, size: 20),
            tooltip: 'Send',
            onPressed: onSend,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }
}

/// Chat side panel showing text messages, file transfers, and images.
class _ChatPanel extends StatelessWidget {
  const _ChatPanel({required this.messages, required this.onOpenFile});

  final List<ChatMessage> messages;
  final void Function(String path) onOpenFile;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1A1A2E),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            color: const Color(0xFF16213E),
            child: const Row(
              children: [
                Icon(Icons.chat, color: Colors.white70, size: 18),
                SizedBox(width: 8),
                Text(
                  'Chat',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          // Messages
          Expanded(
            child: messages.isEmpty
                ? const Center(
                    child: Text(
                      'No messages yet',
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final msg = messages[messages.length - 1 - index];
                      return _ChatBubble(msg: msg, onOpenFile: onOpenFile);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.msg, required this.onOpenFile});

  final ChatMessage msg;
  final void Function(String path) onOpenFile;

  @override
  Widget build(BuildContext context) {
    final timeStr =
        '${msg.time.hour.toString().padLeft(2, '0')}:${msg.time.minute.toString().padLeft(2, '0')}';
    final align = msg.fromMe ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bgColor = msg.fromMe
        ? const Color(0xFF0D47A1)
        : const Color(0xFF2C2C3E);
    final radius = msg.fromMe
        ? const BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(12),
            bottomLeft: Radius.circular(12),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(12),
            bottomRight: Radius.circular(12),
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: align,
        children: [
          Container(
            constraints: const BoxConstraints(maxWidth: 260),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: radius,
            ),
            child: _buildContent(context),
          ),
          const SizedBox(height: 2),
          Text(
            timeStr,
            style: const TextStyle(color: Colors.white30, fontSize: 9),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    switch (msg.type) {
      case ChatMessageType.text:
        return Text(
          msg.text,
          style: const TextStyle(color: Colors.white, fontSize: 13),
        );
      case ChatMessageType.file:
      case ChatMessageType.image:
        final isImage = msg.type == ChatMessageType.image ||
            (msg.fileName.isNotEmpty &&
                _isImageExt(msg.fileName));
        if (isImage && msg.filePath.isNotEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: GestureDetector(
                  onTap: () => onOpenFile(msg.filePath),
                  child: Image.file(
                    File(msg.filePath),
                    width: 180,
                    height: 120,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 180,
                      height: 60,
                      color: Colors.white12,
                      child: const Icon(Icons.broken_image, color: Colors.white38),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                msg.text,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          );
        }
        // File message
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _fileIcon(msg.fileName),
                  color: Colors.white70,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    msg.fileName.isNotEmpty ? msg.fileName : msg.text,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
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
                style: const TextStyle(color: Colors.white54, fontSize: 10),
              ),
            ],
            if (msg.fileDone && msg.filePath.isNotEmpty)
              GestureDetector(
                onTap: () => onOpenFile(msg.filePath),
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
  }

  static bool _isImageExt(String name) {
    final ext = name.split('.').last.toLowerCase();
    return {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'}.contains(ext);
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

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.streaming,
    required this.recording,
    required this.fullscreen,
    required this.chatOpen,
    required this.onBack,
    required this.onHome,
    required this.onRecents,
    required this.onVolumeUp,
    required this.onVolumeDown,
    required this.onPlayPause,
    required this.onScreenshot,
    required this.onRecord,
    required this.onSendFile,
    required this.onFullscreen,
    required this.onChat,
    required this.onClose,
  });

  final bool streaming;
  final bool recording;
  final bool fullscreen;
  final bool chatOpen;
  final VoidCallback onBack;
  final VoidCallback onHome;
  final VoidCallback onRecents;
  final VoidCallback onVolumeUp;
  final VoidCallback onVolumeDown;
  final VoidCallback onPlayPause;
  final VoidCallback onScreenshot;
  final VoidCallback onRecord;
  final VoidCallback onSendFile;
  final VoidCallback onFullscreen;
  final VoidCallback onChat;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    Widget iconButton(IconData icon, VoidCallback onTap, {String? tooltip, bool highlighted = false}) {
      return IconButton(
        icon: Icon(icon, color: highlighted ? Colors.blueAccent : Colors.white),
        tooltip: tooltip,
        onPressed: streaming ? onTap : null,
        style: IconButton.styleFrom(
          backgroundColor: highlighted ? Colors.blueAccent.withAlpha(40) : Colors.black38,
        ),
      );
    }

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        color: Colors.black38,
        child: Row(
          children: [
            iconButton(Icons.close, onClose, tooltip: 'Close (Esc)'),
            const Spacer(),
            iconButton(Icons.arrow_back, onBack, tooltip: 'Back (Ctrl+B)'),
            iconButton(Icons.home, onHome, tooltip: 'Home (Ctrl+H)'),
            iconButton(Icons.apps, onRecents, tooltip: 'Recents (Ctrl+J)'),
            const SizedBox(width: 8),
            iconButton(Icons.volume_down, onVolumeDown, tooltip: 'Volume down (Ctrl+↓)'),
            iconButton(Icons.volume_up, onVolumeUp, tooltip: 'Volume up (Ctrl+↑)'),
            iconButton(Icons.play_arrow, onPlayPause, tooltip: 'Play/pause (Ctrl+Space)'),
            const SizedBox(width: 8),
            iconButton(Icons.photo_camera, onScreenshot, tooltip: 'Screenshot (Ctrl+S)'),
            IconButton(
              icon: Icon(
                recording ? Icons.stop_circle_outlined : Icons.fiber_manual_record,
                color: recording ? Colors.redAccent : Colors.white,
              ),
              tooltip: recording ? 'Stop recording (Ctrl+R)' : 'Record (Ctrl+R)',
              onPressed: onRecord,
            ),
            iconButton(Icons.chat_bubble_outline, onChat,
                tooltip: 'Chat', highlighted: chatOpen),
            iconButton(Icons.upload_file, onSendFile, tooltip: 'Send file to phone'),
            IconButton(
              icon: Icon(
                fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                color: Colors.white,
              ),
              tooltip: fullscreen ? 'Exit fullscreen' : 'Fullscreen',
              onPressed: onFullscreen,
            ),
          ],
        ),
      ),
    );
  }
}
