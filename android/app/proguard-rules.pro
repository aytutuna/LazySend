# kotlinx.serialization and OkHttp ship their own consumer rules.
-keepclassmembers class com.lazysend.lazysend.** {
    *** Companion;
    kotlinx.serialization.KSerializer serializer(...);
}
-keepattributes *Annotation*, InnerClasses
