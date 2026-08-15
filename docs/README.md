# MirrorLink docs

| Document | Read this to… |
| --- | --- |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Understand the components and data flow |
| [PROTOCOL.md](PROTOCOL.md) | Learn the exact wire protocol (discovery, pairing, signaling, data channels) |
| [INSTALLATION.md](INSTALLATION.md) | Install the apps and pair your devices |
| [BUILD.md](BUILD.md) | Build the APK / EXE from source, locally or in CI |
| [SECURITY.md](SECURITY.md) | Understand the security model and report vulnerabilities |
| [PRIVACY.md](PRIVACY.md) | Read what data the apps handle |

Quick overview: the Windows PC hosts discovery + signaling + the WebRTC
answerer; the Android phone captures its screen, offers the peer connection,
and injects input via an AccessibilityService. See the diagram in
[ARCHITECTURE.md](ARCHITECTURE.md).
