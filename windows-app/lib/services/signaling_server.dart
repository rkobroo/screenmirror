import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// WebSocket host that performs pairing and relays WebRTC signaling between
/// the phone and the PC (docs/PROTOCOL.md §3–§4).
///
/// Flow: phone connects → sends `pair` with the 6-digit code → receives a
/// session token → sends its WebRTC `offer` → PC answers → ICE trickle both
/// ways.
class SignalingServer {
  SignalingServer({this.port = 59661});

  final int port;

  HttpServer? _server;
  Timer? _codeTimer;

  String _code = '';
  DateTime _codeExpiry = DateTime.fromMillisecondsSinceEpoch(0);

  final Map<String, WebSocket> _sessionSockets = {};
  final Map<WebSocket, String> _socketSessions = {};
  final Random _random = Random.secure();

  // ---- callbacks -----------------------------------------------------------

  /// Fired when a phone successfully pairs.
  void Function(String session, String ip)? onSessionOpen;

  void Function(String session)? onSessionClose;

  /// The phone's WebRTC offer.
  void Function(String session, String sdp)? onOffer;

  /// An ICE candidate from the phone.
  void Function(String session, Map<String, dynamic> cand)? onIce;

  String get pairingCode => _code;
  DateTime get codeExpiry => _codeExpiry;

  /// Force a fresh code (e.g. after the current one is used or expires).
  String regenerateCode() {
    _newCode();
    return _code;
  }

  Future<void> start() async {
    _newCode();
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen(_handleRequest);
  }

  Future<void> stop() async {
    _codeTimer?.cancel();
    _codeTimer = null;
    _sessionSockets.clear();
    _socketSessions.clear();
    await _server?.close(force: true);
    _server = null;
  }

  /// Send a JSON message to a phone's socket.
  void sendJson(String session, Map<String, dynamic> json) {
    json['s'] = session;
    _sessionSockets[session]?.add(jsonEncode(json));
  }

  // ---- internal -------------------------------------------------------------

  void _newCode() {
    _code = List.generate(6, (_) => _random.nextInt(10)).join();
    _codeExpiry = DateTime.now().add(const Duration(minutes: 2));
    _codeTimer?.cancel();
    _codeTimer = Timer(const Duration(minutes: 2), _newCode);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    socket.listen(
      (data) => _onMessage(socket, data),
      onDone: () => _cleanup(socket),
      onError: (_) => _cleanup(socket),
    );
  }

  void _onMessage(WebSocket socket, dynamic data) {
    if (data is! String) return;
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    switch (msg['t']) {
      case 'pair':
        _handlePair(socket, msg);
      case 'offer':
        if (_authorized(socket, msg)) {
          onOffer?.call(_socketSessions[socket]!, msg['sdp'] as String? ?? '');
        }
      case 'ice':
        if (_authorized(socket, msg)) {
          final cand = msg['cand'];
          if (cand is Map) {
            onIce?.call(
              _socketSessions[socket]!,
              Map<String, dynamic>.from(cand),
            );
          }
        }
      case 'ping':
        socket.add(jsonEncode({'t': 'pong'}));
      case 'answer':
      case 'pong':
        // Phone is the offerer, so it never answers; pings are health-checks.
        break;
    }
  }

  void _handlePair(WebSocket socket, Map<String, dynamic> msg) {
    final code = msg['code'] as String? ?? '';
    if (code.isNotEmpty && code == _code && DateTime.now().isBefore(_codeExpiry)) {
      // Single-use code.
      regenerateCode();
      final session = _newSession();
      _sessionSockets[session] = socket;
      _socketSessions[socket] = session;
      socket.add(jsonEncode({'t': 'paired', 'session': session}));
      onSessionOpen?.call(session, socket.address.address);
    } else {
      socket.add(jsonEncode({'t': 'pairfail', 'reason': 'code'}));
    }
  }

  String _newSession() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  bool _authorized(WebSocket socket, Map<String, dynamic> msg) {
    final session = _socketSessions[socket];
    return session != null && msg['s'] == session;
  }

  void _cleanup(WebSocket socket) {
    final session = _socketSessions.remove(socket);
    if (session != null) {
      _sessionSockets.remove(session);
      onSessionClose?.call(session);
    }
  }
}
