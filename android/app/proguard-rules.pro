# Bridg ProGuard Rules

# Protobuf
-keep class * extends com.google.protobuf.GeneratedMessageLite { *; }
-keep class com.bridg.proto.** { *; }

# Libsodium / crypto
-keep class com.goterl.lazycode.lazysodium.** { *; }

# Don't warn about missing annotations
-dontwarn javax.annotation.**
