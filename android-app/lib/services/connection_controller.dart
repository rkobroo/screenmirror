import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/app_settings.dart';
import '../models/nearby_device.dart';
import 'device_bridge.dart';
import 'discovery_service.dart';
import 'settings_service.dart';
import 'signaling_client.dart';

enum ConnectionState {
  idle,
  discovering,
  pairing,
  negotiating,
  streaming,
  disconnected,
  error,
}

enum ChatMessageType { text, file, image, video }

class ChatMessage {
  const ChatMessage({
    required this.text,
    required this.fromMe,
    required this.time,
    this.type = ChatMessageType.text,
    this.filePath = '',
    this.fileName = '',
  });

  final String text;
  final bool fromMe;
  final DateTime time;
  final ChatMessageType type;
  final String filePath;
  final String fileName;
}

/// Orchestrates the phone side of a session:
///
/// discovery → pairing (WebSocket) → WebRTC negotiation (native) → streaming.
/// Also relays ICE candidates and clipboard/file events between the native
/// bridge and the signaling socket, and updates the UI.
class ConnectionController extends ChangeNotifier {
  ConnectionController({
    required this.bridge,
    required this.signaling,
    required this.discovery,
    required this.settings,
  });

  final DeviceBridge bridge;
  final SignalingClient signaling;
  final DiscoveryService discovery;
  final SettingsService settings;

  final List<NearbyDevice> _devices = [];
  final List<ChatMessage> _messages = [];
  final List<String> _pendingChats = [];

  ConnectionState _state = ConnectionState.idle;
  NearbyDevice? _connectedTo;
  int _fps = 0;
  int _bps = 0;
  String _lastError = '';
  bool _controlChannelOpen = false;

  StreamSubscription<Map<String, dynamic>>? _bridgeSub;
  StreamSubscription<Map<String, dynamic>>? _signalSub;
  StreamSubscription<NearbyDevice>? _discoverySub;

  ConnectionState get state => _state;
  NearbyDevice? get connectedTo => _connectedTo;
  List<NearbyDevice> get devices => List.unmodifiable(_devices);
  int get fps => _fps;
  int get bps => _bps;
  String get lastError => _lastError;
  bool get isStreaming => _state == ConnectionState.streaming;
  bool get isControlOpen => _controlChannelOpen;
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  /// Debounced rebuild throttle for high-frequency stats events.
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> init() async {
    await bridge.init();
    _bridgeSub = bridge.events.listen(_onBridgeEvent);
    _signalSub = signaling.events.listen(_onSignalEvent);
    _discoverySub = discovery.devices.listen(_onDiscovered);
    if (settings.app.autoStart) {
      await startDiscovery();
    }
  }

  // ---- discovery -----------------------------------------------------------

  Future<void> startDiscovery() async {
    await discovery.start();
    _setState(ConnectionState.discovering);
  }

  Future<void> stopDiscovery() async {
    await discovery.stop();
    if (_state == ConnectionState.discovering) {
      _setState(ConnectionState.idle);
    }
  }

  /// Clear the device list and restart discovery (manual rescan).
  Future<void> refreshDiscovery() async {
    _devices.clear();
    notifyListeners();
    await stopDiscovery();
    await startDiscovery();
  }

  void _onDiscovered(NearbyDevice device) {
    final index = _devices.indexWhere((d) => d == device);
    if (index >= 0) {
      _devices[index] = device;
    } else {
      _devices.insert(0, device);
      if (_devices.length > 12) _devices.removeRange(12, _devices.length);
    }
    _throttledNotify();
  }

  // ---- pairing + signaling -------------------------------------------------

  Future<void> connect(NearbyDevice device, String code) async {
    _connectedTo = device;
    _lastError = '';
    _setState(ConnectionState.pairing);
    try {
      await signaling.connect(device, code);
    } catch (e) {
      _fail('Could not reach ${device.ip}: $e');
    }
  }

  Future<void> disconnect() async {
    try { await bridge.stopSession(); } catch (_) {}
    try { await signaling.disconnect(); } catch (_) {}
    _connectedTo = null;
    _fps = 0;
    _bps = 0;
    _controlChannelOpen = false;
    _setState(ConnectionState.idle);
  }

  void _onSignalEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'paired':
        _onPaired().catchError((e) => _fail('Failed to start session: $e'));
        break;
      case 'pairFailed':
        _fail('Pairing rejected by the PC.');
        break;
      case 'answer':
        bridge.setRemoteAnswer(event['sdp'] as String? ?? '');
        break;
      case 'ice':
        final cand = event['cand'];
        if (cand is Map) _handleRemoteIce(cand);
        break;
      case 'error':
        _fail('Connection error: ${event['error'] ?? 'unknown'}');
        break;
      case 'closed':
        _fail('PC disconnected.');
        break;
    }
  }

  Future<void> _onPaired() async {
    try {
      final s = settings.app;
      final maxHeight = s.quality.height;
      final bitrate = switch (s.quality) {
        VideoQuality.low => 2000000,
        VideoQuality.medium => 4000000,
        VideoQuality.high => 8000000,
      };
      final width = (maxHeight * 16 / 9).round();

      await bridge.startSession(
        width: width,
        height: maxHeight,
        fps: s.fps.value,
        bitrate: bitrate,
        autoQuality: s.autoQuality,
        nickname: s.deviceNickname,
        clipboardSync: s.clipboardSync,
      );

      try {
        await bridge.requestProjection();
      } catch (_) {}
    } catch (e) {
      _fail('Failed to start session: $e');
    }
  }

  Future<void> _handleOffer(String sdp) async {
    _setState(ConnectionState.negotiating);
    signaling.sendJson({'t': 'offer', 'sdp': sdp});
  }

  void _handleRemoteIce(Map cand) {
    bridge.addIceCandidate(
      candidate: (cand['candidate'] as String?) ?? '',
      sdpMid: cand['sdpMid'] as String?,
      sdpMLineIndex: (cand['sdpMLineIndex'] as num?)?.toInt(),
    );
  }

  // ---- native bridge events ------------------------------------------------

  void _onBridgeEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case EventType.state:
        final value = event['value'];
        if (value is String) _onNativeState(value);
        break;
      case EventType.offer:
        _handleOffer(event['sdp'] as String? ?? '');
        break;
      case EventType.ice:
        signaling.sendJson({
          't': 'ice',
          'cand': {
            'candidate': event['candidate'],
            'sdpMid': event['sdpMid'],
            'sdpMLineIndex': event['sdpMLineIndex'],
          },
        });
        break;
      case EventType.clipboard:
        _handlePhoneClipboard(event['text'] as String? ?? '');
        break;
      case EventType.chat:
        final text = event['text'] as String? ?? '';
        // Skip the `[Photo: …]` / `[Video: …]` control notices — the actual
        // media arrives as a separate file message with a thumbnail.
        if (text.isNotEmpty &&
            !text.startsWith('[Photo:') &&
            !text.startsWith('[Video:')) {
          _messages.add(ChatMessage(text: text, fromMe: false, time: DateTime.now()));
          notifyListeners();
        }
        break;
      case EventType.dcOpen:
        final channel = event['value'] as String? ?? '';
        debugPrint('[MirrorLink][CHAT_CTRL] dcOpen event: channel=$channel');
        if (channel == 'control') {
          _controlChannelOpen = true;
          _flushPendingChats();
        }
        break;
      case EventType.fileDone:
        final name = event['name'] as String? ?? 'file';
        final filePath = event['filePath'] as String? ?? '';
        final ext = name.split('.').last.toLowerCase();
        if ({'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'}.contains(ext) &&
            filePath.isNotEmpty) {
          _messages.add(ChatMessage(
            text: '[Photo: $name]',
            fromMe: false,
            time: DateTime.now(),
            type: ChatMessageType.image,
            filePath: filePath,
            fileName: name,
          ));
          notifyListeners();
        } else if ({'mp4', 'mkv', 'mov', 'avi', 'webm'}.contains(ext) &&
            filePath.isNotEmpty) {
          _messages.add(ChatMessage(
            text: '[Video: $name]',
            fromMe: false,
            time: DateTime.now(),
            type: ChatMessageType.video,
            filePath: filePath,
            fileName: name,
          ));
          notifyListeners();
        }
        break;
      case EventType.stats:
        _fps = (event['fps'] as num?)?.toInt() ?? 0;
        _bps = (event['bps'] as num?)?.toInt() ?? 0;
        _throttledNotify();
        break;
    }
  }

  void _onNativeState(String value) {
    debugPrint('[MirrorLink][CHAT_CTRL] _onNativeState: $value');
    switch (value) {
      case NativeState.ready:
        _setState(ConnectionState.negotiating);
        break;
      case NativeState.starting:
        _setState(ConnectionState.negotiating);
        break;
      case NativeState.connected:
        _controlChannelOpen = true;
        _setState(ConnectionState.streaming);
        _flushPendingChats();
        break;
      case NativeState.disconnected:
        _controlChannelOpen = false;
        _setState(ConnectionState.disconnected);
        break;
      case NativeState.permissionDenied:
        _lastError = 'Screen capture permission was denied.';
        _setState(ConnectionState.error);
        break;
      default:
        _fail('Native error: $value');
    }
  }

  void _handlePhoneClipboard(String text) {
    if (!settings.app.clipboardSync || text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
  }

  // ---- user actions --------------------------------------------------------

  /// Called from the Home screen's "Start Mirroring" button.
  Future<void> startMirroring() async {
    await bridge.requestProjection();
  }

  /// Send a chat message to the PC.
  void sendChatMessage(String text) {
    if (text.isEmpty) return;
    debugPrint('[MirrorLink][CHAT_CTRL] sendChatMessage: "$text" isStreaming=$isStreaming state=$_state');
    _messages.add(ChatMessage(text: text, fromMe: true, time: DateTime.now()));
    notifyListeners();
    _queueOrSendChat(text);
  }

  void _queueOrSendChat(String text) {
    debugPrint('[MirrorLink][CHAT_CTRL] _queueOrSendChat: isStreaming=$isStreaming controlOpen=$_controlChannelOpen');
    if (isStreaming || _controlChannelOpen) {
      final json = jsonEncode({'type': 'chat', 'text': text});
      debugPrint('[MirrorLink][CHAT_CTRL] _queueOrSendChat: sending via bridge, json=$json');
      bridge.sendData('control', json).then((_) {
        debugPrint('[MirrorLink][CHAT_CTRL] bridge.sendData completed OK');
      }).catchError((e) {
        debugPrint('[MirrorLink][CHAT_CTRL] bridge.sendData FAILED: $e');
      });
    } else {
      debugPrint('[MirrorLink][CHAT_CTRL] _queueOrSendChat: control channel not open, queuing. pendingCount=${_pendingChats.length}');
      _pendingChats.add(text);
    }
  }

  void _flushPendingChats() {
    debugPrint('[MirrorLink][CHAT_CTRL] _flushPendingChats: ${_pendingChats.length} pending');
    while (_pendingChats.isNotEmpty) {
      final text = _pendingChats.removeAt(0);
      final json = jsonEncode({'type': 'chat', 'text': text});
      debugPrint('[MirrorLink][CHAT_CTRL] _flushPendingChats: sending "$text"');
      bridge.sendData('control', json).then((_) {
        debugPrint('[MirrorLink][CHAT_CTRL] _flushPendingChats: bridge.sendData OK');
      }).catchError((e) {
        debugPrint('[MirrorLink][CHAT_CTRL] _flushPendingChats: bridge.sendData FAILED: $e');
      });
    }
  }

  /// Send a photo in chat with a local thumbnail preview.
  void sendPhotoMessage(String path, String fileName) {
    _messages.add(ChatMessage(
      text: '[Photo: $fileName]',
      fromMe: true,
      time: DateTime.now(),
      type: ChatMessageType.image,
      filePath: path,
      fileName: fileName,
    ));
    notifyListeners();
    if (isStreaming || _controlChannelOpen) {
      final json = jsonEncode({'type': 'chat', 'text': '[Photo: $fileName]'});
      bridge.sendData('control', json);
      bridge.sendFile(path);
    }
  }

  /// Send a video in chat with a local preview.
  void sendVideoMessage(String path, String fileName) {
    _messages.add(ChatMessage(
      text: '[Video: $fileName]',
      fromMe: true,
      time: DateTime.now(),
      type: ChatMessageType.video,
      filePath: path,
      fileName: fileName,
    ));
    notifyListeners();
    if (isStreaming || _controlChannelOpen) {
      final json = jsonEncode({'type': 'chat', 'text': '[Video: $fileName]'});
      bridge.sendData('control', json);
      bridge.sendFile(path);
    }
  }

  // ---- misc ----------------------------------------------------------------

  void _fail(String message) {
    _lastError = message;
    _setState(ConnectionState.error);
  }

  void _setState(ConnectionState next) {
    _state = next;
    notifyListeners();
  }

  void _throttledNotify() {
    final now = DateTime.now();
    if (now.difference(_lastNotify).inMilliseconds < 500) return;
    _lastNotify = now;
    notifyListeners();
  }

  @override
  void dispose() {
    _bridgeSub?.cancel();
    _signalSub?.cancel();
    _discoverySub?.cancel();
    super.dispose();
  }
}
