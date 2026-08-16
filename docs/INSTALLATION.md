# Installation

MirrorLink has two parts: the **Windows host** and the **Android client**.
Both must be on the **same Wi-Fi network**.

## Windows (PC)

1. Download the latest `MirrorLink-Windows.zip` from
   [GitHub Releases](https://github.com/rkobroo/screenmirror/releases)
   (or the **Windows bundle** artifact of a CI run).
2. Extract it and run `mirrorlink_windows.exe`.
3. If Windows shows a blue **SmartScreen** prompt, choose **More info → Run
   anyway** (the app is unsigned; this is expected for a hobbyist project).
4. Open MirrorLink. A **6-digit pairing code** appears on the dashboard and the
   app starts broadcasting so your phone can find it.

### "An application control policy has blocked this file" (Smart App Control)

If the app runs once but then won't start from the taskbar with the error
**"An application control policy has blocked this file. Dangerous file
extension from the web"**, the EXE still carries the **Mark of the Web**
(Zone.Identifier) that Windows added when the zip was downloaded. Fix it:

1. Run the helper script (in the repo's `scripts/` folder):
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\Unblock-MirrorLink.ps1
   ```
   Put it in the same folder as the downloaded `MirrorLink-Windows.zip`.
2. **Delete** the old extracted folder, **re-extract** the zip, then **unpin and
   repin** MirrorLink from the taskbar.

> Without the script, do it by hand: right-click the zip → **Properties** →
> tick **Unblock** → OK, then re-extract.

**What's happening:** Windows adds a hidden `Zone.Identifier` stream to any
file downloaded from the web. Smart App Control (Windows 11) and SmartScreen
block unsigned executables carrying that flag. Unblocking removes it. The
permanent fix is a code-signing certificate, which this hobbyist project
doesn't have yet — see [docs/SECURITY.md](SECURITY.md).

> Firewall: the first run will prompt Windows Firewall for ports 59660 (UDP)
> and 59661 (TCP). Allow them on **private networks** only.

## Android (phone)

1. Download the `app-arm64-v8a-release.apk` from the same releases page
   (pick `armeabi-v7a` only if you have a very old phone).
2. Open the APK. If Play Protect complains, tap **More details → Install anyway**
   (the app is open source and installs from an unknown source).
3. Open MirrorLink.

## Pairing

1. Make sure the PC app is running and showing a code.
2. On the phone, tap **Pair device**.
3. The PC should appear automatically under "Discovered PCs" (broadcast over UDP).
   If not, use **Enter code manually** with the code from the PC.
4. Android will ask for **Screen capture** permission → grant it.
5. Android will ask to enable the **MirrorLink accessibility service** →
   go to Settings → Accessibility → MirrorLink → enable it. This is what
   allows the PC to control taps and keys.

Done — you should see your phone's screen on the PC and be able to control it.

## First-run permissions (summary)

| Permission | Purpose | Where |
| --- | --- | --- |
| Screen capture (MediaProjection) | Mirror the display | Prompted at first connect |
| Accessibility service | Inject touch/key input | Android Settings → Accessibility |
| Notifications | Show "mirroring" status | Android Settings → Apps → MirrorLink |

Everything runs locally. No account, no internet required.
