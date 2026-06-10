# Bugly
-dontwarn com.tencent.bugly.**
-keep public class com.tencent.bugly.**{*;}

# Shiply upgrade
-dontwarn com.tencent.upgrade.**
-dontwarn com.tencent.shiply.**
-dontwarn com.tencent.rdelivery.**
-keep public class com.tencent.upgrade.**{*;}
-keep public class com.tencent.shiply.**{*;}
-keep public class com.tencent.rdelivery.**{*;}

# Home Widget - prevent ProGuard from obfuscating widget classes
-keep public class cn.gzus.pro.HomeWidgetProvider {*;}
-keep public class cn.gzus.pro.NextClassWidgetProvider {*;}
-keep public class cn.gzus.pro.TodayScheduleWidgetProvider {*;}
-keep public class cn.gzus.pro.UtilitiesWidgetProvider {*;}
-keep public class cn.gzus.pro.BusinessProgressWidgetProvider {*;}
-keep public class cn.gzus.pro.TodayScheduleService {*;}
-keep public class cn.gzus.pro.TodayScheduleFactory {*;}
-keep public class cn.gzus.pro.BusinessProgressService {*;}
-keep public class cn.gzus.pro.BusinessProgressFactory {*;}

# Keep all RemoteViewsService and RemoteViewsFactory implementations
-keep public class * extends android.widget.RemoteViewsService {*;}
-keep public class * implements android.widget.RemoteViewsService$RemoteViewsFactory {*;}

# Keep widget layouts
-keepclassmembers class **.R$layout {
    public static <fields>;
}

# Keep widget drawables
-keepclassmembers class **.R$drawable {
    public static <fields>;
}

# Keep widget IDs (critical for RemoteViews)
-keepclassmembers class **.R$id {
    public static <fields>;
}

# Keep widget colors
-keepclassmembers class **.R$color {
    public static <fields>;
}

# Keep Flutter font resources and Material Icons
# Note: io.flutter.embedding.* is NOT kept here because it references
# unavailable Play Core classes. Flutter SDK ships its own R8 rules.
-dontwarn com.google.android.play.core.**
-dontwarn com.google.android.play.**
-dontwarn io.flutter.embedding.**
-keepclassmembers class **.R$font {
    public static <fields>;
}
-keepclassmembers class **.R$raw {
    public static <fields>;
}
-keepclassmembers class **.R$mipmap {
    public static <fields>;
}
-keepclassmembers class **.R$drawable {
    public static <fields>;
}
