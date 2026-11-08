# Keep the JNI entry points: their names are resolved by symbol lookup.
-keep class dev.prootbox.app.PtyNative { *; }
-keepclasseswithmembernames class * {
    native <methods>;
}

# Flutter embedding
-keep class io.flutter.** { *; }
-dontwarn io.flutter.embedding.**
