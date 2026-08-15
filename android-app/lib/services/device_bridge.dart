import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// Method-channel contract with the native Kotlin side.
///
/// The native side owns all media: MediaProjection capture, the WebRTC peer
/// connection, data channels, input injection, and clipboard watching.
/// Flutter owns the UI, discovery and signaling transport, and passes JSON
/// signaling back and forth through this bridge.
class DeviceBridge {
  DeviceBridge._();

  static final DeviceBridge instance = DeviceBridge._();

  static const MethodChannel _channel = MethodChannel('mirrorlink/device');
  static const EventChannel _events = EventChannel('mirrorlink/device_events');

  final StreamController<Map<String, dynamic>> _eventController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Stream of native events (see [EventType]).
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  /// Start forwarding native events to Dart listeners.
  Future<void> init() async {
    _events.receiveBroadcastStream().listen((dynamic raw) {
      if (raw is Map) {
        _eventController.add(Map<String, dynamic>.from(raw));
      }
    });
  }

  // ---- device info ---------------------------------------------------------

  Future<Map<String, dynamic>> getDeviceInfo() async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
      'getDeviceInfo',
    );
    return Map<String, dynamic>.from(raw ?? const {});
  }

  Future<bool> isAccessibilityEnabled() async {
    return await _channel.invokeMethod<bool>('isAccessibilityEnabled') ??
        false;
  }

  Future<void> openAccessibilitySettings() =>
      _channel.invokeMethod<void>('openAccessibilitySettings');

  // ---- projection ----------------------------------------------------------

  /// Ask the user for the MediaProjection permission. The result arrives as a
  /// `state` event (`starting` / `permissionDenied`).
  Future<void> requestProjection() =>
      _channel.invokeMethod<void>('requestProjection');

  // ---- session -------------------------------------------------------------

  /// Start the native peer connection. Call after pairing succeeds and the
  /// remote offer is expected.
  Future<void> startSession({
    required int width,
    required int height,
    required int fps,
    required int bitrate,
    required bool autoQuality,
    required String nickname,
    required bool clipboardSync,
  }) {
    return _channel.invokeMethod<void>('startSession', {
      'width': width,
      'height': height,
      'fps': fps,
      'bitrate': bitrate,
      'autoQuality': autoQuality,
      'nickname': nickname,
      'clipboardSync': clipboardSync,
    });
  }

  /// Apply the PC's WebRTC answer SDP (phone is the offerer).
  Future<void> setRemoteAnswer(String sdp) {
    return _channel.invokeMethod<void>('setRemoteAnswer', {
      'sdp': sdp,
    });
  }

  Future<void> addIceCandidate({
    required String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  }) {
    return _channel.invokeMethod<void>('addIceCandidate', {
      'candidate': candidate,
      'sdpMid': sdpMid,
      'sdpMLineIndex': sdpMLineIndex,
    });
  }

  Future<void> stopSession() => _channel.invokeMethod<void>('stopSession');

  /// Send a UTF-8 text payload on the named data channel (phone → PC).
  Future<void> sendData(String channel, String payload) {
    return _channel.invokeMethod<void>('sendData', {
      'channel': channel,
      'payload': base64Encode(utf8.encode(payload)),
    });
  }

  // ---- clipboard -----------------------------------------------------------

  Future<void> setClipboardWatcher(bool enabled) =>
      _channel.invokeMethod<void>('setClipboardWatcher', {'enabled': enabled});

  // ---- file transfer (phone → PC) ------------------------------------------

  /// Stream the SAF [contentUri] (returned by file_picker) to the PC.
  Future<void> sendFile(String contentUri) =>
      _channel.invokeMethod<void>('sendFile', {'uri': contentUri});

  Future<void> dispose() async {
    await _eventController.close();
  }
}

/// Well-known native event names.
abstract class EventType {
  static const state = 'state';
  static const offer = 'offer';
  static const ice = 'ice';
  static const dcOpen = 'dcOpen';
  static const data = 'data';
  static const clipboard = 'clipboard';
  static const fileProgress = 'fileProgress';
  static const fileDone = 'fileDone';
  static const stats = 'stats';
}

/// State values emitted as `state` events.
abstract class NativeState {
  static const starting = 'starting';
  static const connected = 'connected';
  static const disconnected = 'disconnected';
  static const error = 'error';
  static const permissionDenied = 'permissionDenied';
}
