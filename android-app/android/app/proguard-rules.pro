# WebRTC native library (io.github.webrtc-sdk:android) resolves classes by name
# from native code during JNI_OnLoad (LoadGlobalClassReferenceHolder), which R8
# cannot see. Stripping them aborts the app with SIGABRT on the first
# PeerConnectionFactory initialization. Keep all org.webrtc classes intact.
-keep class org.webrtc.** { *; }
