import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/nearby_device.dart';

/// Listens for UDP discovery beacons broadcast by MirrorLink Windows hosts
/// on the local network (see docs/PROTOCOL.md §2).
///
/// Beacons arrive as JSON on port 59660:
/// `{"m":"mirrorlink","v":1,"n":"DESKTOP-X","p":59661,"c":1}`
class DiscoveryService {
  DiscoveryService({this.port = 59660});

  final int port;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _sub;
  final StreamController<NearbyDevice> _found =
      StreamController<NearbyDevice>.broadcast();

  Stream<NearbyDevice> get devices => _found.stream;

  /// Bind the UDP listener. Call [stop] when done.
  Future<void> start() async {
    if (_socket != null) return;
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
      reuseAddress: true,
      reusePort: true,
    );
    socket.broadcastEnabled = true;
    _socket = socket;
    _sub = socket.listen(_onDatagram);
  }

  void _onDatagram(RawSocketEvent event) {
    final socket = _socket;
    if (socket == null) return;
    if (event != RawSocketEvent.read) return;

    final datagram = socket.receive();
    if (datagram == null) return;

    try {
      final json = jsonDecode(utf8.decode(datagram.data, allowMalformed: true));
      if (json is! Map) return;
      if (json['m'] != 'mirrorlink') return;

      final device = NearbyDevice(
        name: (json['n'] as String?) ?? datagram.address.host,
        ip: datagram.address.host,
        port: (json['p'] as num?)?.toInt() ?? 59661,
        accepting: (json['c'] as num?)?.toInt() != 0,
        lastSeen: DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(0)),
      );
      _found.add(device);
    } catch (_) {
      // Ignore malformed or foreign UDP traffic.
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _socket?.close();
    _socket = null;
  }
}
