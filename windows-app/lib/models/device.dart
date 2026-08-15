/// A device session: the connected phone plus its state.
class DeviceSession {
  const DeviceSession({
    required this.id,
    required this.name,
    required this.ip,
    required this.connectedAt,
    this.lastSeenAt,
    this.status = DeviceStatus.paired,
    this.nickname = '',
  });

  final String id;
  final String name;
  final String ip;
  final DateTime connectedAt;
  DateTime? lastSeenAt;
  DeviceStatus status;
  final String nickname;

  bool get isActive => status == DeviceStatus.streaming ||
      status == DeviceStatus.connected;

  DeviceSession copyWith({DeviceStatus? status, DateTime? lastSeenAt}) =>
      DeviceSession(
        id: id,
        name: name,
        ip: ip,
        connectedAt: connectedAt,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        status: status ?? this.status,
        nickname: nickname,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'ip': ip,
        'connectedAt': connectedAt.toIso8601String(),
        'lastSeenAt': lastSeenAt?.toIso8601String(),
        'status': status.name,
        'nickname': nickname,
      };

  factory DeviceSession.fromJson(Map<String, dynamic> json) => DeviceSession(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? 'Unknown phone',
        ip: json['ip'] as String? ?? '',
        connectedAt:
            DateTime.tryParse(json['connectedAt'] as String? ?? '') ??
                DateTime.now(),
        lastSeenAt: json['lastSeenAt'] != null
            ? DateTime.tryParse(json['lastSeenAt'] as String)
            : null,
        status: DeviceStatus.values
            .asNameMap()[json['status']] ??
            DeviceStatus.disconnected,
        nickname: json['nickname'] as String? ?? '',
      );
}

enum DeviceStatus {
  paired,
  connected,
  streaming,
  disconnected,
}

/// A past connection entry for the dashboard history list.
class ConnectionRecord {
  const ConnectionRecord({
    required this.name,
    required this.ip,
    required this.connectedAt,
    required this.duration,
  });

  final String name;
  final String ip;
  final DateTime connectedAt;
  final Duration duration;

  Map<String, dynamic> toJson() => {
        'name': name,
        'ip': ip,
        'connectedAt': connectedAt.toIso8601String(),
        'durationMs': duration.inMilliseconds,
      };

  factory ConnectionRecord.fromJson(Map<String, dynamic> json) =>
      ConnectionRecord(
        name: json['name'] as String? ?? 'Unknown phone',
        ip: json['ip'] as String? ?? '',
        connectedAt: DateTime.tryParse(json['connectedAt'] as String? ?? '') ??
            DateTime.now(),
        duration: Duration(milliseconds: (json['durationMs'] as num?)?.toInt() ?? 0),
      );
}
