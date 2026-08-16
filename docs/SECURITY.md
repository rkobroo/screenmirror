# Security

MirrorLink is designed so that your screen and data stay **inside your own
network**. This document explains the security model and how to report issues.

## Threat model

In scope:

- A malicious device on the same Wi-Fi network
- A hostile network that blocks or intercepts traffic (e.g. a "guest network"
  with AP-isolation)
- Malicious APK/setup binaries (supply-chain; see releases notes below)

Out of scope (by design):

- Compromise of the Windows PC or Android device itself
- A rogue router that already controls both endpoints
- Remote attackers not on your LAN — there is no internet-facing surface

## Controls

| Risk | Mitigation |
| --- | --- |
| Another phone joins your pairing | 6-digit one-time code, 2-minute expiry, stored only as `SHA-256(code\|nonce)`. Brute force is rate-limited (5 attempts, then new code). |
| Sniffing the video stream | WebRTC **DTLS-SRTP** encryption on all media + data channels. |
| Rogue discovery beacons | The app only shows beacons whose magic field equals `mirrorlink`; a device must still pass pairing. |
| Cross-subnet / internet exposure | Signaling and media bind to the LAN interface; Windows Firewall rules are set to **private networks only**. |
| ARP spoofing on the LAN | Not preventable at this layer. Pairing codes provide the authenticity anchor on first connect; treat first connect as the trust root. |

## Pairing details

- The PC shows a fresh code every 2 minutes; a code is **single-use**.
- Only the raw `SHA-256(code || nonce)` is stored in memory; the code itself is
  never written to disk.
- After pairing, a random 128-bit `session` token authenticates the signaling
  socket. The session dies with the socket.

## Data channels

- `control` and `files` are **reliable, ordered** WebRTC data channels → they
  inherit DTLS-SRTP.
- File transfer chunks carry no authentication headers beyond the session —
  a peer you paired with is implicitly trusted for the duration of the session.

## Media

- Host-only ICE candidates by default; media never traverses the internet.
- "Tunnel mode" (WebSocket fallback) exists for AP-isolated networks and is
  disabled unless you enable it in settings.

## Supply chain

- Releases are built **only** by GitHub Actions from tagged commits. Always
  download from the official repository's Releases page.
- No third-party analytics, crash reporters, or telemetry SDKs are compiled in.
- Binaries are **unsigned**. Windows SmartScreen and Smart App Control may
  block them because of the downloaded "Mark of the Web" — see
  [docs/INSTALLATION.md](INSTALLATION.md) for how to unblock. Code signing is
  the long-term fix and is planned; until then, verify the SHA-256 hash of any
  binary against the hash listed on the release page.

## Reporting a vulnerability

Please **do not** open a public issue for security bugs.

Email `security@mirrorlink.app` (or open a GitHub issue only if the bug has no
security impact). Include:

- affected version and platform,
- a minimal reproduction,
- impact assessment, if you have one.

We will acknowledge within 72 hours and coordinate a fix + disclosure.
