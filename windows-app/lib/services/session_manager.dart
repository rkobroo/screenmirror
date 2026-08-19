import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/device.dart';
import 'settings_service.dart';
import 'signaling_server.dart';

enum HostState { idle, paired, negotiating, streaming, error }

@immutable
class Transfer {
  const Transfer({
    required this.id,
    required this.name,
    required this.size,
    required this.direction, // 'to' = PC → phone, 'from' = phone → PC
    this.received = 0,
    this.done = false,
    this.path = '',
  });

  final String id;
  final String name;
  final int size;
  final String direction;
  final int received;
  final bool done;
  final String path;

  double get fraction => size <= 0 ? 0 : (received / size).clamp(0.0, 1.0);

  Transfer copyWith({int? received, bool? done, String? path}) => Transfer(
        id: id,
        name: name,
        size: size,
        direction: direction,
        received: received ?? this.received,
        done: done ?? this.done,
        path: path ?? this.path,
      );
}

enum ChatMessageType { text, file, image, video }

@immutable
class ChatMessage {
  const ChatMessage({
    required this.text,
    required this.fromMe,
    required this.time,
    this.type = ChatMessageType.text,
    this.filePath = '',
    this.fileName = '',
    this.fileSize = 0,
    this.fileProgress = 0,
    this.fileDone = false,
    this.transferId = '',
  });

  final String text;
  final bool fromMe;
  final DateTime time;
  final ChatMessageType type;
  final String filePath;
  final String fileName;
  final int fileSize;
  final int fileProgress;
  final bool fileDone;
  final String transferId;

  double get fraction =>
      fileSize <= 0 ? 0 : (fileProgress / fileSize).clamp(0.0, 1.0);

  ChatMessage copyWith({
    String? text,
    bool? fromMe,
    ChatMessageType? type,
    String? filePath,
    String? fileName,
    int? fileSize,
    int? fileProgress,
    bool? fileDone,
    String? transferId,
  }) =>
      ChatMessage(
        text: text ?? this.text,
        fromMe: fromMe ?? this.fromMe,
        time: time,
        type: type ?? this.type,
        filePath: filePath ?? this.filePath,
        fileName: fileName ?? this.fileName,
        fileSize: fileSize ?? this.fileSize,
        fileProgress: fileProgress ?? this.fileProgress,
        fileDone: fileDone ?? this.fileDone,
        transferId: transferId ?? this.transferId,
      );
}

/// Owns the WebRTC session with the connected phone: negotiates the answer,
/// feeds the incoming video track to the viewer renderer, and manages the
/// `control` + `files` data channels.
class SessionManager extends ChangeNotifier {
  SessionManager({required this.settings});

  final SettingsService settings;

  HostState _state = HostState.idle;
  DeviceSession? _device;
  int _fps = 0;
  int _bps = 0;
  String _error = '';
  Size _captureSize = Size.zero;

  final List<Transfer> _transfers = [];
  final List<ChatMessage> _messages = [];
  final Random _random = Random.secure();

  RTCPeerConnection? _pc;
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  RTCDataChannel? _control;
  RTCDataChannel? _files;
  bool _rendererReady = false;

  HostState get state => _state;
  DeviceSession? get device => _device;
  RTCVideoRenderer get renderer => _renderer;
  int get fps => _fps;
  int get bps => _bps;
  String get error => _error;
  Size get captureSize => _captureSize;
  List<Transfer> get transfers => List.unmodifiable(_transfers);
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  bool get isStreaming => _state == HostState.streaming;

  // ---- inbound file bookkeeping (phone → PC) --------------------------------
  final Map<String, _IncomingFile> _incoming = {};

  SignalingServer? _server;

  /// Wire up to a running [SignalingServer].
  void attach(SignalingServer server) {
    _server = server;
    server.onOffer = _onOffer;
    server.onIce = _onIce;
    server.onSessionOpen = _onSessionOpen;
    server.onSessionClose = _onSessionClose;
  }

  // ---- diagnostics ------------------------------------------------------------

  /// Append a timestamped line to %APPDATA%\com.mirrorlink\mirrorlink_windows\session.log
  /// so negotiation failures are visible even though the dashboard hides them.
  void _log(String message) {
    try {
      final home = Platform.environment['APPDATA'] ??
          Platform.environment['USERPROFILE'] ??
          '.';
      final dir = Directory('$home\\com.mirrorlink\\mirrorlink_windows');
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      File('${dir.path}\\session.log').writeAsStringSync(
        '[${DateTime.now().toIso8601String()}] $message\n',
        mode: FileMode.append,
      );
    } catch (_) {}
    debugPrint('[MirrorLink] $message');
  }

  // ---- signaling -------------------------------------------------------------

  Future<void> _onOffer(String session, String sdp) async {
    _startHeartbeat();
    _log('onOffer: session=$session sdpLen=${sdp.length}');
    _log('onOffer sdp: ${sdp.replaceAll(RegExp(r'\r\n'), ' | ').replaceAll('\n', ' / ')}');
    try {
      await _negotiate(session, sdp)
          .timeout(const Duration(seconds: 30));
    } catch (e, st) {
      _log('onOffer FAILED: $e\n$st');
      _fail('Negotiation failed: $e');
    }
  }

  Future<void> _setRemoteOffer(RTCPeerConnection pc, String sdp) async {
    // NOTE: RTCSessionDescription(sdp, type) — sdp FIRST, type second.
    // Passing ('offer', sdp) sends sdp='offer', type=<sdp>, so native
    // rtc_sdp_type_from_string() returns -1 and setRemoteDescription fails
    // with "Invalid type or sdp".
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
  }

  Future<void> _negotiate(String session, String sdp) async {
    _log('negotiate: ensurePeer...');
    await _ensurePeer();
    final pc = _pc!;
    _setState(HostState.negotiating);

    _log('negotiate: setRemoteDescription...');
    await _setRemoteOffer(pc, sdp);

    _log('negotiate: createAnswer...');
    var sdpText = (await pc.createAnswer({'offerToReceiveVideo': true})).sdp ?? '';
    _log('negotiate: createAnswer ok len=${sdpText.length}');

    // Inject bitrate hint so the phone encoder respects it.
    final bitrateKbps = 4000; // 4 Mbps default
    sdpText = _injectBitrate(sdpText, bitrateKbps);

    final answer = RTCSessionDescription(sdpText, 'answer');
    _log('negotiate: setLocalDescription...');
    await pc.setLocalDescription(answer);
    _log('negotiate: setLocalDescription ok');

    _sendToPhone(session, {'t': 'answer', 'sdp': sdpText});
    _log('negotiate: answer sent to $session');
  }

  void _onIce(String session, Map<String, dynamic> cand) {
    _log('onIce: session=$session cand=${(cand['candidate'] as String? ?? '').split(' ').take(8).join(' ')}');
    _pc?.addCandidate(RTCIceCandidate(
      cand['candidate'] as String? ?? '',
      cand['sdpMid'] as String?,
      (cand['sdpMLineIndex'] as num?)?.toInt(),
    ));
  }

  void _onSessionOpen(String session, String ip) {
    _log('session open: $session ip=$ip');
    _device = DeviceSession(
      id: session,
      name: 'Android phone',
      ip: ip,
      connectedAt: DateTime.now(),
      status: DeviceStatus.paired,
    );
    _setState(HostState.paired);
  }

  void _onSessionClose(String session) {
    _log('session close: $session');
    if (_device?.id == session) {
      _recordHistory();
      _device = null;
      _setState(HostState.idle);
    }
  }

  Future<void> _ensurePeer() async {
    if (_pc != null) {
      _log('ensurePeer: tearing down stale peer from previous session');
      try { await _pc?.close(); } catch (_) {}
      _pc = null;
    }

    if (!_rendererReady) {
      _log('ensurePeer: renderer.initialize()...');
      _renderer.onFirstFrameRendered = () {
        _log('renderer: didFirstFrameRendered — frames ARE reaching the texture');
      };
      _renderer.onResize = () {
        final v = _renderer.value;
        _log('renderer: size=${v.width}x${v.height} renderVideo=${v.renderVideo}');
      };
      await _renderer.initialize();
      _rendererReady = true;
      _log('ensurePeer: renderer ready');
    }

    _log('ensurePeer: createPeerConnection()...');
    final pc = await createPeerConnection({
      'iceServers': [{'urls': 'stun:stun.l.google.com:19302'}, {'urls': 'stun:stun1.l.google.com:19302'}],
    });
    _log('ensurePeer: pc created');

    pc.onDataChannel = (channel) {
      _log('onDataChannel: label=${channel.label}');
      _onDataChannel(channel);
    };
    pc.onTrack = (event) {
      _log('onTrack: kind=${event.track.kind} streams=${event.streams.length}');
      _onTrack(event);
    };
    pc.onIceCandidate = (candidate) {
      final session = _device?.id;
      if (session != null) {
        _sendToPhone(session, {
          't': 'ice',
          'cand': {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        });
      }
    };
    pc.onIceConnectionState = (state) {
      _log('iceConnectionState: $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
        _device?.status = DeviceStatus.streaming;
        _setState(HostState.streaming);
        _scheduleStatsFetches();
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        _stopHeartbeat();
        _device?.status = DeviceStatus.disconnected;
        _setState(HostState.idle);
      }
    };

    _pc = pc;
  }

  void _onDataChannel(RTCDataChannel channel) {
    channel.onMessage = (message) {
      if (channel.label == 'control') {
        _onControlMessage(message);
      } else if (channel.label == 'files') {
        if (message.isBinary) {
          _onFileChunk(message.binary);
        }
      }
    };
    if (channel.label == 'control') {
      _control = channel;
    } else if (channel.label == 'files') {
      _files = channel;
    }
  }

  void _onTrack(RTCTrackEvent event) {
    if (event.track.kind != 'video') return;
    if (event.streams.isNotEmpty) {
      _log('onTrack: set srcObject stream=${event.streams.first.id} ownerTag=${event.streams.first.ownerTag} track=${event.track.id}');
      _renderer.srcObject = event.streams.first;
    } else {
      createLocalMediaStream('phone-screen').then((stream) {
        stream.addTrack(event.track);
        _log('onTrack: no streams, wrapped track in stream id=${stream.id}');
        _renderer.srcObject = stream;
      });
    }
    _device?.status = DeviceStatus.streaming;
    _setState(HostState.streaming);
  }

  // ---- PC-side receive diagnostics -------------------------------------------

  Timer? _hbTimer;
  int _hb = 0;

  void _startHeartbeat() {
    _stopHeartbeat();
    _hb = 0;
    _hbTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _hb++;
      _log('hb: $_hb');
    });
  }

  void _stopHeartbeat() {
    _hbTimer?.cancel();
    _hbTimer = null;
  }

  void _scheduleStatsFetches() {
    Timer(const Duration(seconds: 2), () => _fetchStats('t+2s'));
    Timer(const Duration(seconds: 8), () => _fetchStats('t+8s'));
  }

  Future<void> _fetchStats(String label) async {
    final pc = _pc;
    if (pc == null) {
      _log('pcstats: $label pc-null');
      return;
    }
    _log('pcstats: $label start');
    try {
      final reports = await pc.getStats().timeout(const Duration(seconds: 3));
      final types = <String>{};
      for (final r in reports) {
        types.add(r.type);
        if (r.type == 'inbound-rtp' && r.values['kind'] == 'video') {
          final v = r.values;
          _log('pcstats: $label video bytes=${v['bytesReceived']} packets=${v['packetsReceived']} framesRcvd=${v['framesReceived']} framesDecoded=${v['framesDecoded']} dropped=${v['framesDropped']} keyDecoded=${v['keyFramesDecoded']} decoder=${v['decoderImplementation']} codec=${v['codecId']} jitter=${v['jitter']}');
        }
      }
      _log('pcstats: $label done reports=${reports.length} types=$types');
    } catch (e) {
      _log('pcstats: $label error $e');
    }
  }

  void _onControlMessage(RTCDataChannelMessage message) {
    final raw = message.isBinary
        ? String.fromCharCodes(message.binary)
        : message.text;
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      _log('control msg PARSE FAILED: raw=${raw.length > 200 ? raw.substring(0, 200) : raw}');
      return;
    }

      _log('control msg type=${json['type']}');
      switch (json['type']) {
      case 'clipboard':
        _applyIncomingClipboard(json['text'] as String? ?? '');
        break;
      case 'ping':
        _sendControl({'type': 'pong'});
        break;
      case 'stats':
        _log('phone stats: fps=${json['fps']} bps=${json['bps']}');
        _fps = (json['fps'] as num?)?.toInt() ?? _fps;
        _bps = (json['bps'] as num?)?.toInt() ?? _bps;
        notifyListeners();
        break;
      case 'dimensions':
        final w = (json['width'] as num?)?.toDouble() ?? 0;
        final h = (json['height'] as num?)?.toDouble() ?? 0;
        if (w > 0 && h > 0) {
          _captureSize = Size(w, h);
          _log('phone dimensions: ${w}x$h');
          notifyListeners();
        }
        break;
      case 'chat':
        final text = json['text'] as String? ?? '';
        _log('CHAT RECEIVED: "$text" isEmpty=${text.isEmpty}');
        // Skip the `[Photo: …]` / `[Video: …]` control notices — the actual
        // media arrives as a separate file message with a thumbnail.
        if (text.isNotEmpty &&
            !text.startsWith('[Photo:') &&
            !text.startsWith('[Video:')) {
          _messages.add(ChatMessage(
            text: text,
            fromMe: false,
            time: DateTime.now(),
          ));
          notifyListeners();
        }
        break;
      case 'file':
        _onFileControl(json);
        break;
      case 'pong':
        break;
    }
  }

  // ---- clipboard (PC → phone) ------------------------------------------------

  Future<void> _applyIncomingClipboard(String text) async {
    if (text.isEmpty || !settings.app.notifications) return;
    await Clipboard.setData(ClipboardData(text: text));
    onIncomingClipboard?.call(text);
  }

  /// Called by the clipboard watcher when the PC clipboard changes.
  Future<void> sendClipboard(String text) async {
    if (!isStreaming || text.isEmpty) return;
    _sendControl({'type': 'clipboard', 'text': text});
    onClipboardSent?.call(text);
  }

  /// Set when the phone pushes clipboard text to the PC (used to suppress the
  /// PC→phone echo loop in the clipboard watcher).
  void Function(String text)? onIncomingClipboard;
  void Function(String text)? onClipboardSent;
  void Function(String name, String path)? onFileReceived;

  // ---- remote input (PC → phone) ---------------------------------------------

  void sendTouch(double x, double y, int action) =>
      _sendControl({'type': 'input', 'kind': 'touch', 'x': x, 'y': y, 'action': action});

  void sendSwipe(List<List<double>> points, int duration) =>
      _sendControl({'type': 'input', 'kind': 'swipe', 'points': points, 'duration': duration});

  void sendScroll(double dx, double dy) =>
      _sendControl({'type': 'input', 'kind': 'scroll', 'dx': dx, 'dy': dy});

  void sendKey(int code, int action) =>
      _sendControl({'type': 'input', 'kind': 'key', 'code': code, 'action': action});

  void sendText(String value) => _sendControl({'type': 'input', 'kind': 'text', 'value': value});

  /// Send a chat text message and add it to the local message list.
  void sendChatMessage(String text) {
    if (text.isEmpty) return;
    _messages.add(ChatMessage(
      text: text,
      fromMe: true,
      time: DateTime.now(),
    ));
    notifyListeners();
    if (_control != null) {
      _sendControl({'type': 'chat', 'text': text});
    }
  }

  void sendSysButton(String button) =>
      _sendControl({'type': 'input', 'kind': 'sys', 'button': button});

  void sendVolume(String dir) =>
      _sendControl({'type': 'input', 'kind': 'volume', 'dir': dir});

  void sendMedia(String action) =>
      _sendControl({'type': 'input', 'kind': 'media', 'action': action});

  // ---- file transfer (PC → phone) ---------------------------------------------

  /// Stream a local file to the phone. When [chatMessage] is false the
  /// transfer still happens (and shows in the transfers card) but no extra
  /// "Sending …" chat bubble is added — used for inline chat photos/videos.
  Future<void> sendFileToPhone(String path, {bool chatMessage = true}) async {
    final channel = _files;
    if (channel == null) return;

    final id = _newId();
    final file = File(path);
    final size = await file.length();
    final name = file.uri.pathSegments.last;

    _transfers.insert(0, Transfer(id: id, name: name, size: size, direction: 'to'));
    if (chatMessage) {
      _messages.add(ChatMessage(
        text: 'Sending $name',
        fromMe: true,
        time: DateTime.now(),
        type: ChatMessageType.file,
        fileName: name,
        fileSize: size,
        transferId: id,
      ));
    }
    notifyListeners();

    _sendControl({
      'type': 'file',
      'op': 'send',
      'id': id,
      'name': name,
      'size': size,
      'mime': _mimeFromExtension(name),
    });

    final header = ByteData(24);
    final idBytes = Uint8List.fromList(utf8.encode(id).take(16).toList());
    header.buffer.asUint8List().setRange(0, idBytes.length, idBytes);

    final stream = file.openRead();
    var offset = 0;
    await for (final chunk in stream) {
      final frame = ByteData(24 + chunk.length);
      frame.buffer.asUint8List().setAll(0, header.buffer.asUint8List());
      frame.buffer.asUint8List().setRange(24, 24 + chunk.length, chunk);
      frame.setUint64(16, offset);
      // send() awaits the native stack, which provides natural backpressure.
      await channel.send(RTCDataChannelMessage.fromBinary(
        frame.buffer.asUint8List(),
      ));
      offset += chunk.length;
      _updateTransfer(id, received: offset);
    }

    _sendControl({'type': 'file', 'op': 'done', 'id': id});
    _updateTransfer(id, done: true);
    final msgIdx = _messages.indexWhere((m) => m.transferId == id);
    if (msgIdx >= 0) {
      _messages[msgIdx] = _messages[msgIdx].copyWith(text: '$name sent', fileDone: true);
    }
    notifyListeners();
  }

  /// Send a photo in chat, showing a local thumbnail immediately and
  /// transferring the file to the phone.
  void sendPhotoMessage(String path, String fileName) {
    final name =
        fileName.isNotEmpty ? fileName : File(path).uri.pathSegments.last;
    _messages.add(ChatMessage(
      text: '[Photo: $name]',
      fromMe: true,
      time: DateTime.now(),
      type: ChatMessageType.image,
      filePath: path,
      fileName: name,
    ));
    notifyListeners();
    if (_control != null) _sendControl({'type': 'chat', 'text': '[Photo: $name]'});
    sendFileToPhone(path, chatMessage: false);
  }

  /// Send a video in chat, showing a local thumbnail immediately and
  /// transferring the file to the phone.
  void sendVideoMessage(String path, String fileName) {
    final name =
        fileName.isNotEmpty ? fileName : File(path).uri.pathSegments.last;
    _messages.add(ChatMessage(
      text: '[Video: $name]',
      fromMe: true,
      time: DateTime.now(),
      type: ChatMessageType.video,
      filePath: path,
      fileName: name,
    ));
    notifyListeners();
    if (_control != null) _sendControl({'type': 'chat', 'text': '[Video: $name]'});
    sendFileToPhone(path, chatMessage: false);
  }

  // ---- inbound file transfer (phone → PC) --------------------------------------

  bool _isMediaFile(String name) {
    final ext = name.split('.').last.toLowerCase();
    return const {
      'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp',
      'mp4', 'mkv', 'mov', 'avi', 'webm'
    }.contains(ext);
  }

  void _onFileControl(Map<String, dynamic> json) {
    final id = json['id'] as String? ?? '';
    switch (json['op']) {
      case 'send':
        final name = json['name'] as String? ?? 'file';
        final size = (json['size'] as num?)?.toInt() ?? 0;
        _transfers.insert(0, Transfer(id: id, name: name, size: size, direction: 'from'));
        // For chat photos/videos the thumbnail arrives on completion, so don't
        // show the raw filename as a separate bubble here.
        if (!_isMediaFile(name)) {
          _messages.add(ChatMessage(
            text: 'Receiving $name',
            fromMe: false,
            time: DateTime.now(),
            type: ChatMessageType.file,
            fileName: name,
            fileSize: size,
            transferId: id,
          ));
        }
        notifyListeners();
        break;
      case 'done':
        final file = _incoming.remove(id);
        if (file != null) {
          file.sink.close();
          _updateTransfer(id, done: true, path: file.path);
          _log('file received: ${file.path}');
          final transfer = _transfers.firstWhere(
            (t) => t.id == id,
            orElse: () => Transfer(id: id, name: file.path.split('\\').last, size: 0, direction: 'from'),
          );
          _messages.add(ChatMessage(
            text: _isMediaFile(transfer.name) ? '' : '${transfer.name} saved',
            fromMe: false,
            time: DateTime.now(),
            type: ChatMessageType.file,
            fileName: transfer.name,
            filePath: file.path,
            fileSize: transfer.size,
            fileProgress: transfer.size,
            fileDone: true,
          ));
          onFileReceived?.call(transfer.name, file.path);
        }
        break;
      case 'error':
        _incoming.remove(id)?.sink.close();
        break;
    }
  }

  void _onFileChunk(Uint8List frame) {
    if (frame.length < 24) return;
    final header = frame.sublist(0, 24);
    final id = String.fromCharCodes(header.takeWhile((b) => b != 0));
    final data = ByteData.sublistView(Uint8List.fromList(frame));
    final offset = data.getUint64(16);
    final payload = frame.sublist(24);

    final file = _incoming[id] ?? _openIncoming(id);
    if (file == null) return;
    _incoming[id] = file;
    file.sink.add(payload);
    _updateTransfer(id, received: offset + payload.length);
  }

  _IncomingFile? _openIncoming(String id) {
    try {
      final dir = _saveDirectory();
      final name = _transfers.firstWhere(
        (t) => t.id == id,
        orElse: () => Transfer(id: id, name: 'file', size: 0, direction: 'from'),
      ).name;
      final path = _uniquePath(dir, name);
      final sink = File(path).openWrite();
      return _IncomingFile(path, sink);
    } catch (_) {
      return null;
    }
  }

  Directory _saveDirectory() {
    final configured = settings.app.saveDirectory;
    if (configured.isNotEmpty) {
      return Directory(configured)..createSync(recursive: true);
    }
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '.';
    return Directory('$home\\Documents\\MirrorLink')..createSync(recursive: true);
  }

  String _uniquePath(Directory dir, String name) {
    var candidate = File('${dir.path}\\$name');
    if (!candidate.existsSync()) return candidate.path;
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    for (var i = 1; ; i++) {
      candidate = File('${dir.path}\\$base ($i)$ext');
      if (!candidate.existsSync()) return candidate.path;
    }
  }

  // ---- misc --------------------------------------------------------------------

  void _updateTransfer(String id, {int? received, bool? done, String? path}) {
    final index = _transfers.indexWhere((t) => t.id == id);
    if (index >= 0) {
      _transfers[index] = _transfers[index].copyWith(
        received: received,
        done: done,
        path: path,
      );
    }
    // Also update the corresponding chat message.
    final msgIdx = _messages.indexWhere((m) => m.transferId == id);
    if (msgIdx >= 0) {
      _messages[msgIdx] = _messages[msgIdx].copyWith(
        fileProgress: received,
        fileDone: done,
        filePath: path,
      );
    }
    notifyListeners();
  }

  String _mimeFromExtension(String name) {
    final ext = name.split('.').last.toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'mp4' => 'video/mp4',
      'mkv' => 'video/x-matroska',
      'avi' => 'video/x-msvideo',
      'mov' => 'video/quicktime',
      'webm' => 'video/webm',
      'mp3' => 'audio/mpeg',
      'wav' => 'audio/wav',
      'ogg' => 'audio/ogg',
      'pdf' => 'application/pdf',
      'apk' => 'application/vnd.android.package-archive',
      'zip' => 'application/zip',
      'txt' => 'text/plain',
      'html' => 'text/html',
      'json' => 'application/json',
      _ => 'application/octet-stream',
    };
  }

  void _sendControl(Map<String, dynamic> json) {
    _control?.send(RTCDataChannelMessage(jsonEncode(json)));
  }

  void _sendToPhone(String session, Map<String, dynamic> json) {
    _server?.sendJson(session, json);
  }

  String _injectBitrate(String sdp, int kbps) {
    return sdp.replaceFirstMapped(
      RegExp(r'(m=video\s+\d+\s+[^\r\n]+)'),
      (m) => '${m.group(0)}\r\nb=AS:$kbps',
    );
  }

  void _setState(HostState next) {
    if (_state != next) {
      _state = next;
      notifyListeners();
    }
  }

  void _fail(String message) {
    _log('FAIL: $message');
    _error = message;
    _setState(HostState.error);
  }

  void _recordHistory() {
    final device = _device;
    if (device == null) return;
    final duration = DateTime.now().difference(device.connectedAt);
    if (duration.inSeconds > 0) {
      settings.addHistory(ConnectionRecord(
        name: device.nickname.isNotEmpty ? device.nickname : device.name,
        ip: device.ip,
        connectedAt: device.connectedAt,
        duration: duration,
      ));
    }
  }

  String _newId() => _random.nextInt(0x7FFFFFFF).toRadixString(16);

  Future<void> close() async {
    _recordHistory();
    _stopHeartbeat();
    _incoming.forEach((_, f) => f.sink.close());
    _incoming.clear();
    _control = null;
    _files = null;
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    if (_rendererReady) {
      _renderer.dispose();
      _rendererReady = false;
    }
    _device = null;
    _fps = 0;
    _bps = 0;
    _setState(HostState.idle);
  }

  @override
  void dispose() {
    close();
    super.dispose();
  }
}

class _IncomingFile {
  _IncomingFile(this.path, this.sink);
  final String path;
  final IOSink sink;
}

