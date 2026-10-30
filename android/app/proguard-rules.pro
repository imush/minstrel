# shared_preferences_android 2.5 calls its Kotlin API from Dart through JNI
# (package:jni), looking classes, methods and fields up by name and
# signature, and ships no keep rules. R8 renamed or removed the Kotlin
# classes those lookups name, so release builds crashed at startup
# (NoSuchMethodError, then ClassNotFoundException; Play build 1.0.0 (2)
# did). Keep every class the Dart side names: the plugin's, the jni glue's,
# and these from the Kotlin standard library.
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep class com.github.dart_lang.jni.** { *; }
-keep class kotlin.coroutines.Continuation { *; }
-keep class kotlin.coroutines.intrinsics.CoroutineSingletons { *; }
-keep class kotlin.coroutines.intrinsics.IntrinsicsKt { *; }
-keep class kotlin.enums.EnumEntries { *; }
-keep class kotlin.jvm.internal.DefaultConstructorMarker { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.Unit { *; }
