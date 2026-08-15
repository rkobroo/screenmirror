# MirrorLink Protocol v1

This document defines the wire protocol between the Android phone and the
Windows PC. Everything runs on the **local network** — no cloud servers.

The Windows PC is the **host**. The Android phone is the **client**.

```
Phone ── UDP discovery beacons ─────────────► PC listens on :59660
Phone ── WebSocket signaling ws://ip:59661 ─► PC hosts pairing + SDP relay
Phone ── WebRTC peer connection ────────────► PC renders video, sends input
```

## 1. Ports

| Port  | Transport | Owner  | Purpose |
|-------|-----------|--------|---------|
| 59660 | UDP       | Phone binds, PC broadcasts | Device discovery beacons |
| 59661 | TCP/WSS   | PC hosts                  | Pairing + signaling + WebSocket fallback |

Ports are configurable in each app's settings. Both apps assume a single LAN
subnet; multicast is avoided to work on more routers (broadcast instead).

## 2. Discovery

The PC broadcasts a beacon every **3 seconds** to `255.255.255.255:59660`:

```json
{ "m": "mirrorlink", "v": 1, "n": "DESKTOP-7F3A", "p": 59661, "c": 1 }
```

| Field | Meaning |
|-------|---------|
| `m`   | Magic string, must equal `mirrorlink` |
| `v`   | Protocol version |
| `n`   | Human-readable PC name shown in the pairing list |
| `p`   | Signaling WebSocket port on the PC |
| `c`   | `1` = currently accepting connections |

The phone listens on `:59660` and lists every beacon it hears. Tapping an
entry connects to `ws://<source-ip>:<p>`.

## 3. Pairing

1. The PC generates a **6-digit code** plus a matching **QR payload** and shows
   them on screen. The code is stored only as `SHA-256(code || nonce)`; the
   nonce is kept in memory. A code expires after **2 minutes** and is
   single-use.
2. The phone opens `ws://<ip>:59661` and sends:

   ```json
   { "t": "pair", "code": "123456" }
   ```

3. On success the PC replies:

   ```json
   { "t": "paired", "session": "c8f9…" }
   ```

   `session` is a random 128-bit hex token valid for the life of the
   WebSocket. All subsequent signaling messages carry `"s": "<session>"`.
   The code is invalidated immediately.
4. On failure the PC replies `{ "t": "pairfail", "reason": "code" | "busy" }`.

The QR payload is `mirrorlink://pair?ip=<ip>&port=<port>&code=<code>`, which
the Android app can scan or paste as a manual pairing string.

## 4. Signaling (over the paired WebSocket)

The **phone initiates the WebRTC negotiation** because it owns the screen
video track and the data channels. The PC is the pure answerer, which keeps
negotiation trivial (no SDP munging, no renegotiation on the PC).

| Direction | Message |
|-----------|---------|
| Phone → PC | `{ "t": "offer", "s": session, "sdp": "…" }` |
| PC → Phone | `{ "t": "answer", "s": session, "sdp": "…" }` |
| either →   | `{ "t": "ice", "s": session, "cand": { "candidate": "…", "sdpMid": "…", "sdpMLineIndex": 0 } }` |
| either →   | `{ "t": "ping" }` / `{ "t": "pong" }` heartbeat every 15 s |

ICE uses only **host candidates** (LAN) to keep it fast and private. If the
host-candidate path is blocked, the WebSocket itself can be used as a fallback
transport for a constrained media path (see §8).

## 5. WebRTC setup

- **Phone (offerer):**
  - creates the data channels `control` and `files` (reliable, ordered);
  - adds its **screen video track** (`send` direction, VP8/VP9/H264);
  - creates the offer and streams it through the signaling socket.
- **PC (answerer):**
  - sets the remote offer, answers, and listens for
    `onDataChannel` + `onTrack` (video).
- DTLS-SRTP encrypts all media; data channels run over DTLS too.

The phone's video track exists even before MediaProjection permission is
granted (it just produces no frames), so the same negotiation covers both
cases. Resolution changes do not require renegotiation.

## 6. Data channels

Two reliable, ordered `RTCDataChannel`s:

### `control` — commands and small payloads

Input (PC → Phone):

```json
{ "type": "input", "kind": "touch",  "x": 0.42, "y": 0.67, "action": 0 }
{ "type": "input", "kind": "swipe",  "points": [[0.1,0.5],[0.9,0.5]], "duration": 150 }
{ "type": "input", "kind": "scroll", "dx": 0, "dy": -120 }
{ "type": "input", "kind": "key",    "code": 29, "action": 0 }
{ "type": "input", "kind": "text",   "value": "hello" }
{ "type": "input", "kind": "sys",    "button": "home" | "back" | "recents" }
{ "type": "input", "kind": "volume", "dir": "up" | "down" | "mute" }
{ "type": "input", "kind": "media",  "action": "play" | "pause" | "next" | "prev" }
```

Touch coordinates are **normalized 0..1** in landscape-relative space; the
phone maps them to its display. Touch `action`: `0` down, `1` move, `2` up.

Clipboard (both directions):

```json
{ "type": "clipboard", "text": "copied content" }
```

File transfer control (both directions):

```json
{ "type": "file", "op": "send", "id": "uuid", "name": "doc.pdf", "size": 12345, "mime": "application/pdf" }
{ "type": "file", "op": "ack",  "id": "uuid", "offset": 65536 }
{ "type": "file", "op": "done", "id": "uuid" }
{ "type": "file", "op": "error", "id": "uuid", "reason": "disk" }
```

Heartbeat is `{ "type": "ping" }` / `{ "type": "pong" }` every 15 s.

### `files` — binary chunks

Each chunk is `24 byte header + payload`:

```
bytes 0..15  uuid (16 bytes)
bytes 16..23 file offset (little-endian uint64)
bytes 24+    payload
```

Chunk payload is at most **64 KiB**. Ordering is guaranteed by the reliable
channel. The receiver treats a chunk whose offset equals the declared size as
end-of-file (and closes on `{ "op": "done" }`).

## 7. Screen stream

- Phone captures the display with `MediaProjection` at the configured quality
  (default 720p / 30 fps / 4 Mbps), feeds frames into a WebRTC `VideoSource`,
  and renegotiates if the resolution changes.
- The PC renders the track in the remote viewer. It scales to fit and supports
  fullscreen, screenshot, and recording.
- The phone periodically sends `{ "type": "stats", "fps": 29, "bps": 4200000 }`
  over `control` so the PC can display live quality and auto-adjust
  (auto quality adjustment = the phone adapts capture resolution/bitrate when
  frames drop).

## 8. WebSocket fallback

If a host ICE candidate cannot connect (rare on LAN — e.g. guest network
AP-isolation), the apps can tunnel media frames over the paired WebSocket as a
last resort. This mode is marked **"Tunnel mode"** and disabled by default.
Tunnel mode reuses the `files` channel framing over `Binary` WebSocket
messages with a `{ "t": "tunnel", "m": "video" }` text header first.

## 9. Connection lifecycle

1. Phone sees beacon → user taps **Connect** (or enters code manually).
2. Pairing completes → PC sends `offer`.
3. Phone answers → media flows.
4. Either side may close; on `close` the peer shows "Disconnected" and the
   phone can auto-reconnect by re-running discovery + pairing (requires a new
   code; the PC keeps the previous nickname in connection history).
