# MirrorLink — Windows app

PC-side host for MirrorLink. Pairs with your Android phone over Wi-Fi and
shows/controls it live.

## Stack

- **Flutter** + **flutter_webrtc** for the viewer, signaling and data channels
- `dart:io` WebSocket + UDP broadcast servers — no cloud, everything on your LAN

## Key files

| Path | Purpose |
| --- | --- |
| `lib/screens/dashboard_screen.dart` | Pairing code, device, history |
| `lib/screens/viewer_screen.dart` | Live viewer + remote control + capture |
| `lib/services/session_manager.dart` | WebRTC host, data channels, transfers |
| `lib/services/signaling_server.dart` | Pairing + signaling WebSocket host |
| `lib/services/discovery_broadcaster.dart` | UDP beacons so phones can find the PC |
| `lib/services/mjpeg_writer.dart` | Dependency-free MJPEG/AVI recorder |

## Build

The `windows/` runner folder is generated — see [docs/BUILD.md](../docs/BUILD.md).

```bash
flutter create --platforms windows --project-name mirrorlink_windows .
flutter pub get
flutter build windows --release
```
