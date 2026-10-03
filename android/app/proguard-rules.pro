# JNI entry points are called from native code and from the JVM by name.
-keep class com.jxcode.android.llama.LlamaBridge { *; }
-keep class com.jxcode.android.terminal.PtyNative { *; }
-keepclasseswithmembernames class * {
    native <methods>;
}

# Wire models are (de)serialised reflectively by kotlinx.serialization.
-keepclassmembers class com.jxcode.android.wire.** { *; }
-keepattributes *Annotation*, InnerClasses, Signature

# The provider list is persisted to providers.json, so its generated
# serializers have to survive shrinking too — otherwise a release build stops
# decoding the file a debug build wrote, and every registered backend
# disappears on upgrade. `data.**` was missing here while `wire.**` was not.
-keepclassmembers class com.jxcode.android.data.** { *; }
-keep,includedescriptorclasses class com.jxcode.android.data.**$$serializer { *; }
-keepclassmembers class com.jxcode.android.data.**$Companion { *; }
