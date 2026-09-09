# Bridg ProGuard Rules

# Protobuf
-keep class * extends com.google.protobuf.GeneratedMessageLite { *; }
-keep class com.bridg.proto.** { *; }

# Libsodium (lazysodium 5.x lives under com.goterl.lazysodium, not the old
# com.goterl.lazycode.lazysodium — the stale rule matched nothing and R8
# mangled the classes, crashing the app on launch).
-keep class com.goterl.lazysodium.** { *; }
-keep class com.goterl.resourceloader.** { *; }
-dontwarn com.goterl.lazysodium.**

# JNA — lazysodium reaches libsodium through JNA, which binds native methods
# by reflection and must not be renamed or stripped.
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.** { *; }
-dontwarn com.sun.jna.**
-dontwarn java.awt.**

# Don't warn about missing annotations
-dontwarn javax.annotation.**
