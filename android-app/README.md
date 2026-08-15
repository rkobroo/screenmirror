# MirrorLink — Android app

Phone side of MirrorLink. Wirelessly mirrors your screen to a Windows PC and
lets you control it from there.

## Stack

- **Flutter** for UI (`lib/`)
- **Native Kotlin** for media: MediaProjection capture, WebRTC peer
  connection, data channels, input injection, clipboard watching
  (`android/app/src/main/kotlin/com/mirrorlink/android/`)

## Key files

| Path | Purpose |
| --- | --- |
| `lib/screens/` | Splash, Home, Pairing, Settings |
| `lib/services/connection_controller.dart` | Orchestrates discovery → pairing → streaming |
| `lib/services/signaling_client.dart` | WebSocket signaling client |
| `lib/services/device_bridge.dart` | Method-channel contract with native code |
| `android/…/RtcEngine.kt` | Native WebRTC + screen capture pipeline |
| `android/…/InputAccessibilityService.kt` | Remote input injection |
| `android/…/ScreenProjectionService.kt` | MediaProjection foreground service |

## Build

See [docs/BUILD.md](../docs/BUILD.md). Requires Flutter ≥ 3.24 and a JDK.

```bash
flutter pub get
flutter build apk --release
```
