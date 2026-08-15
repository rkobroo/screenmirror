# MirrorLink Architecture

Two halves, one protocol, zero servers. The **PC is the host**, the **Android
phone is the client**, and everything travels over your local Wi-Fi.

```
                 ┌─────────────────────── LAN ───────────────────────┐
                 │                                                     │
┌────────────────┴─────────┐                          ┌───────────────┴─────────┐
│  Android phone (client)   │                          │  Windows PC (host)      │
│                          │   UDP broadcast beacon   │                         │
│  DiscoveryClient         │ ◄───────────────────────  │  DiscoveryBroadcaster    │
│  PairingController       │   WebSocket ws://ip:59661 │  SignalingServer (WS)    │
│  RtcEngine (offerer)     │ ◄───────────────────────► │  SessionManager (answer) │
│    ScreenProjectionService│  WebRTC DTLS-SRTP        │    RTCVideoRenderer      │
│    MediaProjection capture│  video track + data chs  │    ControlHub            │
│    InputAccessibilityService ◄──────── input ───────  │    mouse/keyboard        │
│    FileServer/MirrorLink   │                          │                         │
└──────────────────────────┘                          └─────────────────────────┘
```

## Android app (`android-app/`)

| Component | File | Role |
| --- | --- | --- |
| Flutter UI | `lib/` | Home, pairing list, viewer status, settings |
| `ScreenProjectionService` | `android/app/src/main/kotlin/.../ScreenProjectionService.kt` | Foreground service holding `MediaProjection`, feeds frames into WebRTC |
| `InputAccessibilityService` | `.../InputAccessibilityService.kt` | Receives `input` messages and injects taps/swipes/keys/scrolls |
| `RtcEngine` | `.../RtcEngine.kt` | Native `PeerConnection`, SDP offer, data channels, capture track |
| `MirrorLinkMainActivity` | `.../MirrorLinkMainActivity.kt` | Screen-capture permission result → starts projection |

Native side (Kotlin) talks to Flutter via a `MethodChannel`. Native code owns
`MediaProjection` and the WebRTC peer connection; Flutter owns screens and
settings. Input injection uses the platform **AccessibilityService**, which can
dispatch touches (`dispatchGesture`) and key events without a foreground
requirement.

## Windows app (`windows-app/`)

| Component | File | Role |
| --- | --- | --- |
| Dashboard | `lib/screens/dashboard_screen.dart` | Pairing code, discovered phones, history |
| Viewer | `lib/screens/viewer_screen.dart` | Renders the remote video, captures input |
| `SignalingServer` | `lib/services/signaling_server.dart` | WebSocket host: pairing, SDP relay, session tokens |
| `SessionManager` | `lib/services/session_manager.dart` | WebRTC answerer, data channels, file receive |
| `DiscoveryBroadcaster` | `lib/services/discovery_broadcaster.dart` | UDP beacons every 3 s |
| `MjpegWriter` | `lib/services/mjpeg_writer.dart` | Records the viewer to MJPEG/AVI |

The Windows app listens on ports 59660 (UDP discovery) and 59661 (WebSocket
signaling). `flutter_webrtc` handles media on this side; no native Windows
code is required beyond the standard Flutter runner.

## Data flow

1. **Discovery** — PC broadcasts a beacon; phone lists nearby PCs.
2. **Pairing** — phone connects over WebSocket and sends a one-time 6-digit
   code; PC issues a `session` token.
3. **Negotiation** — phone creates the WebRTC offer (owns the video track and
   data channels); PC answers. ICE is host-only.
4. **Media** — phone's `MediaProjection` frames → VP8/VP9/H264 → PC viewer.
5. **Control** — PC mouse/keyboard → `control` data channel →
   `InputAccessibilityService` on the phone.
6. **Files** — `files` data channel with a 24-byte header per 64 KiB chunk.
7. **Clipboard** — both directions over the `control` channel.

## Design decisions

- **PC answers, phone offers.** The phone owns the media and data channels, so
  it initiates — no renegotiation or SDP munging on the PC.
- **Broadcast beats multicast.** More routers support it, and discovery only
  needs one subnet.
- **Host-only ICE.** Keeps media on the LAN, fast and private. A WebSocket
  "tunnel mode" exists as a fallback for AP-isolated guest networks.
- **AccessibilityService over `adb` input.** No adb, no USB, no root; works on
  stock Android as long as the user enables the accessibility service.
- **Native WebRTC on Android, `flutter_webrtc` on Windows.** The phone SDK
  handles MediaProjection capture + data channels most reliably; Flutter's
  WebRTC plugin keeps the desktop side lightweight.

See [PROTOCOL.md](PROTOCOL.md) for the exact wire format.
