/// A PC discovered on the local network via UDP beacon, or entered manually.
class NearbyDevice {
  const NearbyDevice({
    required this.name,
    required this.ip,
    required this.port,
    this.accepting = true,
    this.lastSeen = const Duration.zero,
  });

  final String name;
  final String ip;
  final int port;
  final bool accepting;
  final Duration lastSeen;

  @override
  bool operator ==(Object other) =>
      other is NearbyDevice && other.ip == ip && other.port == port;

  @override
  int get hashCode => Object.hash(ip, port);

  NearbyDevice copyWith({
    String? name,
    String? ip,
    int? port,
    bool? accepting,
    Duration? lastSeen,
  }) {
    return NearbyDevice(
      name: name ?? this.name,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      accepting: accepting ?? this.accepting,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}
