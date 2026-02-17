# Keep PedroSG94 RootEncoder library classes
-keep class com.pedro.** { *; }
-keep interface com.pedro.** { *; }

# Keep ConnectChecker interface
-keep interface com.pedro.common.ConnectChecker { *; }

# General Android rules
-keepattributes *Annotation*
-keepattributes SourceFile,LineNumberTable
-keep public class * extends java.lang.Exception

# Kotlin
-keep class kotlin.** { *; }
-keep class kotlinx.** { *; }