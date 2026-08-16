import 'dart:async';

import 'package:flutter/services.dart';

import 'session_manager.dart';

/// Watches the PC clipboard and pushes changes to the connected phone.
///
/// Windows exposes no clipboard-changed event to Dart, so we poll every
/// 2 seconds and diff against the last seen value. The phone→PC direction is
/// received by [SessionManager.onIncomingClipboard], which updates [_last] to
/// prevent an echo loop.
class ClipboardSync {
  ClipboardSync(this.session);

  final SessionManager session;
  Timer? _timer;
  String _last = '';

  void start() {
    stop();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _poll() async {
    if (!session.isStreaming) return;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text ?? '';
      if (text.isNotEmpty && text != _last) {
        _last = text;
        session.sendClipboard(text);
      }
    } catch (_) {
      // Clipboard read failed; try again next tick.
    }
  }

  /// The phone pushed clipboard text to the PC — remember it so we don't
  /// echo it back.
  void onIncoming(String text) {
    if (text.isNotEmpty) _last = text;
  }
}
