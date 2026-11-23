# kotlinx.serialization and OkHttp ship their own consumer rules; ONNX Runtime's native code finds its Java classes by name.
-keep class ai.onnxruntime.** { *; }
-keepclassmembers class com.lazysend.lazysend.** {
    *** Companion;
    kotlinx.serialization.KSerializer serializer(...);
}
-keepattributes *Annotation*, InnerClasses
