# Privacy

MirrorLink is a **local, offline-first** tool. This page states exactly what
data it handles.

## Short version

- No accounts, no telemetry, no analytics, no ads.
- Nothing leaves your local network except your own screen data (which itself
  stays on your network).
- The apps can be fully uninstalled, leaving no data behind except your own
  connection history and settings.

## What the Android app does with data

| Data | Use | Transmitted? |
| --- | --- | --- |
| Screen content (while mirroring) | Streamed to your PC over WebRTC | LAN only, DTLS-SRTP encrypted |
| Clipboard content (while syncing) | Sent to the paired PC (and received from it) | LAN only |
| Files you transfer | Sent/received over the `files` data channel | LAN only |
| Accessibility events (taps, keys) | Injected from PC input commands | LAN only |
| Connection history (PC names, last-used IPs) | Shown in the pairing list | Stored locally on the phone |
| Settings (quality, ports, toggles) | Applied locally | Not transmitted |

## What the Windows app does with data

| Data | Use | Transmitted? |
| --- | --- | --- |
| Pairing code (in memory) | Verified against the phone's code | In memory only |
| PC name | Sent in discovery beacons so your phone can find it | LAN broadcast only |
| Connection history | Shown in the dashboard | Stored locally |
| Received files | Saved to your chosen folder | LAN only |

## What the website does with data

- The landing page is static; it calls one Cloudflare Pages Function that
  proxies the public GitHub **latest release** metadata (tag, notes, download
  URLs). No personal data is involved.
- Cloudflare's standard access logs may record IP addresses, as is normal for
  any website.

## Third parties

| Party | Purpose |
| --- | --- |
| GitHub | Hosts the source repository and release binaries |
| Cloudflare Pages | Hosts the website and its one API function |

Neither service sees your phone or PC traffic.

## Retention & deletion

- Connection history is stored via `shared_preferences` on each device.
  Clearing app data (Android) or deleting the config file (Windows) removes it.
- Screen, clipboard and file data are **never persisted** beyond the transfer
  itself.

## Contact

Questions about this policy: `privacy@mirrorlink.app`.
