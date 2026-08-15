import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

import '../models/nearby_device.dart';

/// Signaling events delivered to the connection controller.
enum SignalEvent { paired, pairFailed, offer, answer, ice, pong, closed, error }

/// WebSocket client that talks to the MirrorLink Windows host for pairing and
/// WebRTC signaling (docs/PROTOCOL.md §3–§4).
class SignalingClient {
  SignalingClient._();

  static final SignalingClient instance = SignalingClient._();

  WebSocketChannel? _channel;
  Timer? _heartbeat;
  bool _manualClose = false;

  String _session = '';
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Stream of `{type: SignalEvent, ...}` payloads.
  Stream<Map<String, dynamic>> get events => _events.stream;

  bool get isOpen => _channel != null;

  /// Pair with the PC using its 6-digit [code], then negotiate WebRTC.
  Future<void> connect(NearbyDevice device, String code) async {
    await disconnect();

    _manualClose = false;
    final uri = Uri.parse('ws://${device.ip}:${device.port}');
    final channel = IOWebSocketChannel.connect(uri, pingInterval: null);
    _channel = channel;

    channel.stream.listen(
      _onMessage,
      onError: (Object error) {
        _emit(SignalEvent.error, {'error': '$error'});
        _cleanup();
      },
      onDone: () {
        if (!_manualClose) _emit(SignalEvent.closed, {'reason': 'done'});
        _cleanup();
      },
    );

    // Wait for the socket to be open before sending the pair request.
    await channel.ready;
    sendJson({'t': 'pair', 'code': code});

    _heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_channel != null) sendJson({'t': 'ping'});
    });
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    switch (msg['t']) {
      case 'paired':
        _session = (msg['session'] as String?) ?? '';
        _emit(SignalEvent.paired);
      case 'pairfail':
        _emit(SignalEvent.pairFailed, {'reason': msg['reason']});
      case 'offer':
        _emit(SignalEvent.offer, {'sdp': msg['sdp']});
      case 'answer':
        _emit(SignalEvent.answer, {'sdp': msg['sdp']});
      case 'ice':
        _emit(SignalEvent.ice, {'cand': msg['cand']});
      case 'pong':
        _emit(SignalEvent.pong);
    }
  }

  /// Send a raw JSON message (with session attached when present).
  void sendJson(Map<String, dynamic> json) {
    if (_session.isNotEmpty && !json.containsKey('s')) {
      json['s'] = _session;
    }
    final channel = _channel;
    if (channel == null) return;
    channel.sink.add(jsonEncode(json));
  }

  void _emit(SignalEvent type, [Map<String, dynamic>? extra]) {
    _events.add({
      'type': type.name,
      if (extra != null) ...extra,
    });
  }

  Future<void> disconnect() async {
    _manualClose = true;
    _heartbeat?.cancel();
    _heartbeat = null;
    _session = '';
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      await channel.sink.close();
    }
  }

  void _cleanup() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _session = '';
    _channel = null;
  }
}
