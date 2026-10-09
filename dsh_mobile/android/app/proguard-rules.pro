# Flutter + 本项目依赖的 ProGuard / R8 规则。
#
# minifyEnabled 打开后 R8 会裁剪"看起来没被引用"的类，而 Flutter 的部分能力是
# 通过反射 / JNI 回调的，静态分析看不出来。裁错了表现为**运行时**崩溃
# （ClassNotFound / NoSuchMethod），而且往往只在 release 包出现 —— debug 包不做
# 混淆，所以本地怎么测都测不出来。

# Flutter 引擎本体由 flutter 插件自带的 consumer rules 覆盖；这里保留显式声明，
# 避免将来某个插件版本调整了规则集时静默失效。
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# 插件注册表：GeneratedPluginRegistrant 在运行时按名字查找插件类。
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }

# speech_to_text 通过 MethodChannel 与原生通信，回调带 @Keep 之外还有枚举/泛型擦除。
-keep class com.google.android.gms.actions.** { *; }
-keep class com.google.firebase.** { *; }
-keep class io.flutter.plugins.googleassistant** { *; }
-dontwarn com.google.android.gms.**

# Play Core（deferred components）是 Flutter 的 PlayStoreSplitApplication /
# PlayStoreDeferredComponentManager 引用的可选依赖。这个 App **不使用** deferred
# components（用的是标准 split-per-abi 打包），所以这些类根本不会在 classpath 上。
# 但 R8 仍会因为 Flutter 的代码路径引用它们而报 "Missing class" 并中断构建。
#
# 处理方式不是去加 Play Core 依赖（那会平白多几 MB 且引入一个用不到的库），
# 而是声明"知道它们缺失、我不用"。这是 R8 官方推荐的 -dontwarn 用法。
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.**
-dontwarn io.flutter.app.FlutterPlayStoreSplitApplication

# Dart 侧反射用到的类型（dart:mirrors / json 序列化常见）。
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod

# 保留行号，便于线上崩溃栈可读（release 构建也保留，代价是包大几 KB）。
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# 去掉不影响功能但会撑大包的日志与调试代码。
-assumenosideeffects class android.util.Log {
    public static *** v(...);
    public static *** d(...);
    public static *** i(...);
}