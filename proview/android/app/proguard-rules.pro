# ProView's native engine looks these up by name over JNI; R8 must not rename or strip them.
-keep class app.proview.proview.NativeEngine { *; }
-keep class app.proview.proview.NativePlayer { *; }
-keep interface app.proview.proview.NativeEngine$ConvertListener { *; }
-keep class * implements app.proview.proview.NativeEngine$ConvertListener { *; }

# ML Kit finds its components by class name at start-up (MlKitInitProvider); R8 must keep them or the
# image-labeling, face and text models silently fail to load.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
-keep class * implements com.google.firebase.components.ComponentRegistrar { *; }
-keep class * implements com.google.mlkit.common.sdkinternal.ModelResource { *; }
-dontwarn com.google.mlkit.**
