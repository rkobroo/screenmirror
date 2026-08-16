# Building from source

## Prerequisites

- [Flutter](https://flutter.dev) stable channel
- **Android build:** JDK 17 + Android SDK (compile SDK 35)
- **Windows build:** Windows 10/11 + Visual Studio 2022 with the "Desktop
  development with C++" workload

## Android app (`android-app/`)

```bash
cd android-app
flutter pub get
flutter build apk --release          # fat APK
flutter build apk --release --split-per-abi
```

Output: `android-app/build/app/outputs/flutter-apk/`.

The Android app uses the **native WebRTC SDK**
(`io.github.webrtc-sdk:android`) for MediaProjection capture, peer connection
and data channels — no C++ toolchain needed on the Android side.

## Windows app (`windows-app/`)

The `windows/` platform runner **is committed** to the repo (it carries the
Impeller-disable engine switch required for flutter_webrtc's external video
textures). If you regenerate it, re-apply the switch in `runner/main.cpp`:

```cpp
::SetEnvironmentVariableA("FLUTTER_ENGINE_SWITCHES", "1");
::SetEnvironmentVariableA("FLUTTER_ENGINE_SWITCH_1", "enable-impeller=false");
```

Then build:

```bash
cd windows-app
flutter create --platforms windows --project-name mirrorlink_windows --org com.mirrorlink .
flutter pub get
flutter build windows --release
```

Output: `windows-app/build/windows/x64/runner/Release/mirrorlink_windows.exe`.

> Note: `flutter create ... --project-name mirrorlink_windows` must match the
> name in `pubspec.yaml` or the build will fail.

## CI builds (GitHub Actions)

`.github/workflows/build.yml`:

- on every push / PR: builds the APK (Linux) and the EXE (Windows) and uploads
  them as workflow artifacts;
- on tag push (`v*`): creates a GitHub **Release** with both binaries attached.

The Windows runner folder is regenerated in CI with `flutter create`, so
locally you only need to generate it once.

## Website (`website/`)

Static site + one Cloudflare Pages Function (`/api/release`). No build step:

```bash
cd website
npx wrangler pages deploy website --project-name=mirrorlink
```

Deploys automatically on pushes to `main` via
`.github/workflows/website.yml` (requires `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID` secrets).
