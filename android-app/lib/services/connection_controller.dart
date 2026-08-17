import 'dart:async';

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

class ChatMessage {
  const ChatMessage({
    required this.text,
    required this.fromMe,
    required this.time,
  });

  final String text;
  final bool fromMe;
  final DateTime time;
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

  ConnectionState _state = ConnectionState.idle;
  NearbyDevice? _connectedTo;
  int _fps = 0;
  int _bps = 0;
  String _lastError = '';

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
    await bridge.stopSession();
    await signaling.disconnect();
    _connectedTo = null;
    _fps = 0;
    _bps = 0;
    _setState(ConnectionState.idle);
  }

  void _onSignalEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'paired':
        _onPaired();
        break;
      case 'pairFailed':
        _fail('Pairing rejected by the PC.');
        break;
      case 'answer':
        bridge.setRemoteAnswer(event['sdp'] as String? ?? '');
        break;
      case 'ice':
        _handleRemoteIce(event['cand'] as Map);
        break;
      case 'closed':
        _fail('PC disconnected.');
        break;
    }
  }

  Future<void> _onPaired() async {
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

    // The Home button becomes "Stop Mirroring" the moment ICE connects, so
    // the projection-permission dialog would otherwise be unreachable during
    // the normal connect flow. Request it here so capture starts alongside
    // the mirroring session (the user can still deny to decline video).
    try {
      await bridge.requestProjection();
    } catch (_) {}
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
        _onNativeState(event['value'] as String);
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
        if (text.isNotEmpty) {
          _messages.add(ChatMessage(text: text, fromMe: false, time: DateTime.now()));
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
    switch (value) {
      case NativeState.ready:
        // Native peer is up and the offer is ready; wait for negotiation.
        _setState(ConnectionState.negotiating);
        break;
      case NativeState.starting:
        _setState(ConnectionState.negotiating);
        break;
      case NativeState.connected:
        _setState(ConnectionState.streaming);
        break;
      case NativeState.disconnected:
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
    if (text.isEmpty || !isStreaming) return;
    final json = '{"type":"chat","text":"${text.replaceAll('"', '\\"')}"}';
    bridge.sendData('control', json);
    _messages.add(ChatMessage(text: text, fromMe: true, time: DateTime.now()));
    notifyListeners();
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
