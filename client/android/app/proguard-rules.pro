# R8/ProGuard rules for the release build.
#
# flutter_local_notifications (17.2.4) serialises its Android-side models with
# gson, which reads generic type information (TypeToken) from class files at
# runtime. R8 strips generic signatures by default, so an unconfigured release
# build dies at plugin init with:
#   java.lang.IllegalStateException: TypeToken must be created with a type
#   argument ... make sure that generic signatures are preserved.
# Debug builds never shrink, which is why this only ever appeared on device
# release APKs (fourth E2E finding).
#
# The gson block below is the plugin's documented configuration, copied
# verbatim from the v17.2.4 example app:
# https://github.com/MaikuB/flutter_local_notifications/blob/flutter_local_notifications-v17.2.4/flutter_local_notifications/example/android/app/proguard-rules.pro
# (which matches gson's own android-proguard-example). v19+ drops gson and
# with it this requirement — delete this block when the plugin is upgraded
# past that.

## Gson rules
# Gson uses generic type information stored in a class file when working with fields. Proguard
# removes such information by default, so configure it to keep all of it.
-keepattributes Signature

# For using GSON @Expose annotation
-keepattributes *Annotation*

# Gson specific classes
-dontwarn sun.misc.**
#-keep class com.google.gson.stream.** { *; }

# Prevent proguard from stripping interface information from TypeAdapter, TypeAdapterFactory,
# JsonSerializer, JsonDeserializer instances (so they can be used in @JsonAdapter)
-keep class * extends com.google.gson.TypeAdapter
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer

# Prevent R8 from leaving Data object members always null
-keepclassmembers,allowobfuscation class * {
  @com.google.gson.annotations.SerializedName <fields>;
}

# Retain generic signatures of TypeToken and its subclasses with R8 version 3.0 and higher.
-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class * extends com.google.gson.reflect.TypeToken

## flutter_local_notifications plugin classes
# The plugin's model classes (NotificationDetails and friends) are gson-mapped
# by REFLECTION over plain fields — no @SerializedName — so the rules above do
# not protect their field names from being renamed or stripped. The plugin
# ships no consumer rules in 17.x; keep its classes whole.
-keep class com.dexterous.flutterlocalnotifications.** { *; }
