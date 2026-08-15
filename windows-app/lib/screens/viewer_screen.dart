import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
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
  MjpegWriter? _writer;
  Timer? _recTimer;
  bool _fullscreen = false;

  AppServices? _services;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _stopRecording();
    super.dispose();
  }

  // ---- input: mouse ----------------------------------------------------------

  Offset _normalize(Offset local, Size size) {
    if (size.isEmpty) return Offset.zero;
    return Offset(
      (local.dx / size.width).clamp(0.0, 1.0),
      (local.dy / size.height).clamp(0.0, 1.0),
    );
  }

  void _onPointerDown(PointerDownEvent e, Size size) {
    final services = _services!;
    if (!services.session.isStreaming) return;
    final p = _normalize(e.localPosition, size);
    _dragStart = p;
    _lastDrag = p;
    services.session.sendTouch(p.dx, p.dy, 0);
  }

  void _onPointerMove(PointerMoveEvent e, Size size) {
    final services = _services!;
    if (!services.session.isStreaming || _dragStart == null) return;
    final p = _normalize(e.localPosition, size);
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

  void _onPointerUp(PointerUpEvent e, Size size) {
    final services = _services!;
    if (!services.session.isStreaming) return;
    final p = _normalize(e.localPosition, size);
    final start = _dragStart ?? p;
    final moved = (start - p).distance > 0.05;
    if (!moved) {
      // Simple tap.
      services.session.sendTouch(p.dx, p.dy, 2);
    }
    _dragStart = null;
    _lastDrag = null;
  }

  // ---- input: keyboard -------------------------------------------------------

  bool _onKey(KeyEvent event) {
    final services = _services;
    if (services == null || !services.session.isStreaming) return false;
    if (event is! KeyDownEvent || event.repeat) return false;

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
    const map = <LogicalKeyboardKey, int>{
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
      final image = await _capture();
      if (image == null) return;
      final data = await image.toByteData(format: ui.ImageByteFormat.jpeg, quality: 70);
      image.dispose();
      if (data == null) return;
      _writer?.addJpeg(data.buffer.asUint8List());
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
    await _services!.session.sendFileToPhone(path);
  }

  Future<void> _toggleFullscreen() async {
    final next = !_fullscreen;
    await windowManager.setFullScreen(next);
    if (mounted) setState(() => _fullscreen = next);
  }

  // ---- build --------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context);
    _services = services;
    final session = services.session;

    return Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedBuilder(
        animation: session,
        builder: (context, _) {
          final streaming = session.isStreaming;

          return Stack(
            children: [
              Positioned.fill(
                child: Listener(
                  onPointerDown: (e) => _onPointerDown(e, _viewSize(context)),
                  onPointerMove: (e) => _onPointerMove(e, _viewSize(context)),
                  onPointerUp: (e) => _onPointerUp(e, _viewSize(context)),
                  onPointerCancel: (_) => _dragStart = null,
                  onPointerScroll: (e) {
                    if (session.isStreaming) {
                      session.sendScroll(e.scrollDelta.dx, e.scrollDelta.dy);
                    }
                  },
                  child: RepaintBoundary(
                    key: _boundaryKey,
                    child: streaming
                        ? _VideoView(session: session)
                        : _NoStreamPlaceholder(error: session.error),
                  ),
                ),
              ),
              _Toolbar(
                streaming: streaming,
                recording: _recording,
                fullscreen: _fullscreen,
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
            ],
          );
        },
      ),
    );
  }

  Size _viewSize(BuildContext context) =>
      MediaQuery.of(context).size;
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

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.streaming,
    required this.recording,
    required this.fullscreen,
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
    required this.onClose,
  });

  final bool streaming;
  final bool recording;
  final bool fullscreen;
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
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    Widget iconButton(IconData icon, VoidCallback onTap, {String? tooltip}) {
      return IconButton(
        icon: Icon(icon, color: Colors.white),
        tooltip: tooltip,
        onPressed: streaming ? onTap : null,
        style: IconButton.styleFrom(
          backgroundColor: Colors.black38,
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
