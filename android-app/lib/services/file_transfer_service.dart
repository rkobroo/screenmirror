import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';

import 'device_bridge.dart';

enum TransferDirection { toPc, fromPc }

enum TransferStatus { running, done, failed }

@immutable
class Transfer {
  const Transfer({
    required this.id,
    required this.name,
    required this.direction,
    required this.size,
    this.received = 0,
    this.status = TransferStatus.running,
  });

  final String id;
  final String name;
  final TransferDirection direction;
  final int size;
  final int received;
  final TransferStatus status;

  double get fraction => size <= 0 ? 0 : (received / size).clamp(0.0, 1.0);

  Transfer copyWith({int? received, TransferStatus? status}) => Transfer(
        id: id,
        name: name,
        direction: direction,
        size: size,
        received: received ?? this.received,
        status: status ?? this.status,
      );
}

/// Tracks PC↔phone file transfers. The heavy lifting (chunking, MediaStore
/// writes, reading SAF content) happens natively; this service only listens
/// for progress events and exposes the list to the UI.
class FileTransferService extends ChangeNotifier {
  FileTransferService(this._bridge) {
    _sub = _bridge.events.listen(_onEvent);
  }

  final DeviceBridge _bridge;
  StreamSubscription<Map<String, dynamic>>? _sub;
  final List<Transfer> _transfers = [];
  final StreamController<Transfer> _completed =
      StreamController<Transfer>.broadcast();

  List<Transfer> get transfers => List.unmodifiable(_transfers);

  /// Fires when a transfer reaches [TransferStatus.done].
  Stream<Transfer> get completed => _completed.stream;

  void _onEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case EventType.fileProgress:
        final id = event['id'] as String?;
        if (id == null) return;
        final received = (event['received'] as num?)?.toInt() ?? 0;
        final total = (event['total'] as num?)?.toInt() ?? 0;
        _upsert(id, received: received, total: total);
      case EventType.fileDone:
        final id = event['id'] as String?;
        final name = event['name'] as String? ?? 'file';
        if (id == null) return;
        _upsert(id, done: true, name: name, total: 0);
    }
  }

  void _upsert(
    String id, {
    int? received,
    int? total,
    bool? done,
    String? name,
  }) {
    final index = _transfers.indexWhere((t) => t.id == id);
    final existing = index >= 0 ? _transfers[index] : null;

    if (existing == null) {
      _transfers.add(Transfer(
        id: id,
        name: name ?? 'transfer',
        direction: TransferDirection.fromPc,
        size: total ?? 0,
        received: received ?? 0,
      ));
    } else {
      final updated = existing.copyWith(
        received: received ?? existing.received,
        status: done == true ? TransferStatus.done : existing.status,
      );
      _transfers[index] = updated;
      if (done == true) {
        _completed.add(updated);
        // Keep the last few finished transfers for the UI, drop the rest.
        if (_transfers.length > 20) {
          _transfers.removeWhere(
            (t) => t.status == TransferStatus.done && t.id != id,
          );
        }
      }
    }
    notifyListeners();
  }

  /// Pick a file on the phone and stream it to the PC.
  Future<void> sendFileToPc() async {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;

    await _bridge.sendFile(path);
    // The native side reports progress via the standard event path; register
    // a placeholder so the UI updates immediately.
    _transfers.insert(
      0,
      Transfer(
        id: 'pending',
        name: result.files.single.name,
        direction: TransferDirection.toPc,
        size: result.files.single.size,
      ),
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _completed.close();
    super.dispose();
  }
}
