import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Broadcasts UDP discovery beacons so Android phones can find this PC
/// (docs/PROTOCOL.md §2). Beacon: `{"m":"mirrorlink","v":1,"n":..,"p":59661,"c":1}`
class DiscoveryBroadcaster {
  DiscoveryBroadcaster({this.beaconPort = 59660, this.interval = const Duration(seconds: 3)});

  final int beaconPort;
  final Duration interval;

  RawDatagramSocket? _socket;
  Timer? _timer;

  Future<void> start({required String deviceName, required int signalingPort}) async {
    await stop();
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      beaconPort,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;
    _socket = socket;

    // Drain inbound (phones currently don't respond, but keep the buffer clean).
    socket.listen((_) => socket.receive());

    _timer = Timer.periodic(interval, (_) {
      final beacon = jsonEncode({
        'm': 'mirrorlink',
        'v': 1,
        'n': deviceName,
        'p': signalingPort,
        'c': 1,
      });
      try {
        socket.send(
          utf8.encode(beacon),
          InternetAddress('255.255.255.255'),
          beaconPort,
        );
      } catch (_) {
        // Network may not be ready yet; retry next tick.
      }
    });
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _socket?.close();
    _socket = null;
  }
}
