package com.example.dsh_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.annotation.Nullable
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    /** 分享接收：SEND intent 带来的内容，Dart 侧启动时消费一次。 */
    private var pendingShare: MutableMap<String, String>? = null

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureShareIntent(intent)
    }

    /** 把 SEND intent 的文字/图片 URI 暂存，等 Dart 侧来取。 */
    private fun captureShareIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        val map = mutableMapOf<String, String>()
        if (intent.type == "text/plain") {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: ""
            if (text.isNotBlank()) map["text"] = text
        } else if (intent.type?.startsWith("image/") == true) {
            @Suppress("DEPRECATION")
            val uri = intent.getParcelableExtra<android.net.Uri>(Intent.EXTRA_STREAM)
            if (uri != null) map["imagePath"] = uri.toString()
        }
        if (map.isNotEmpty()) pendingShare = map
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 冷启动分享：intent 在 Activity 创建时就已就位。
        captureShareIntent(intent)

        // 语音输入：App 调用 startListening，插件起原生识别器；结果与错误
        // 经 EventChannel 回传。这里只做"点击时若 App 已退到后台就把前台服务
        // 拉起来"的联动，识别本身交给 speech_to_text 插件。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_METHODS)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startForeground" -> {
                        val ctx = applicationContext
                        val started = try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                ctx.startForegroundService(Intent(ctx, GatewayKeepAliveService::class.java))
                            } else {
                                ctx.startService(Intent(ctx, GatewayKeepAliveService::class.java))
                            }
                            true
                        } catch (e: Exception) {
                            // Android 12+ 对后台启动前台服务有限制；失败不是致命错误，
                            // 只是这次没有后台保活能力。明确回传 false 让 Dart 侧
                            // 能如实告诉用户"后台收不到通知"，而不是假装已经开始。
                            false
                        }
                        result.success(started)
                    }
                    "stopForeground" -> {
                        try {
                            stopService(Intent(applicationContext, GatewayKeepAliveService::class.java))
                        } catch (_: Exception) {
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // 打开外部 URL（APK 下载直链等）。Dart 侧没有内建的系统浏览器出口，
        // 也不用 url_launcher —— 只为一个动线加一个插件不值。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_URL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrBlank()) {
                            result.error("bad-args", "url is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val intent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            // 没有浏览器可处理时如实回传，Dart 侧提示复制直链。
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 分享接收：Dart 侧启动时来取一次，取走即清（避免下次启动重复注入）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_SHARE)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumePending" -> {
                        val share = pendingShare
                        pendingShare = null
                        result.success(share)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        private const val CHANNEL_METHODS = "dsh_mobile/foreground"
        private const val CHANNEL_URL = "dsh_mobile/url"
        private const val CHANNEL_SHARE = "dsh_mobile/share"
    }
}

/**
 * 前台服务：仅用于让通知在后台常驻可见。
 *
 * 为什么需要它：Android 一旦把 App 切到后台并判定它不活跃，就会回收进程，
 * WebSocket 随之断开，于是"有新事件"这件事永远不会发生 —— 推送通知也就无从谈起。
 * 前台服务是系统明确提供的、唯一能让进程长期存活的正规途径（代价是常驻一条
 * 通知，用户可见、可随时划掉）。
 *
 * 这个 Service 本身不建立网络连接，它只是"存在"以维持进程优先级；真正的
 * 连接仍在 Dart 侧。这么分是为了把网络/重连/鉴权的全部复杂度留在 Dart，
 * 而原生侧只有一个状态明确、可以审计的实现。
 */
class GatewayKeepAliveService : android.app.Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()
        val notification: Notification = buildNotification()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10+ 要求 startForeground 时声明类型，且必须与 manifest 中
            // 声明的 foregroundServiceType 一致，否则抛 IllegalStateException。
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // START_STICKY：进程被系统杀掉后系统会重建它。对"随时要收到推送"这个
        // 目标是必需的 —— 但它也意味着进程在无人使用时可能被反复拉起，所以
        // Dart 侧必须在不需要通知时明确 stopForeground（上面 channel 的
        // stopForeground 分支）。
        return START_STICKY
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            "网关连接",
            // LOW：常驻通知不弹横幅、不震动。事件提醒走另一个 HIGH 渠道。
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "保持与网关的连接，以便在后台收到新事件提醒"
            setShowBadge(false)
        }
        nm.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        // 点击通知回到 App。FLAG_IMMUTABLE 是 Android 12+ 的强制要求。
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pi = PendingIntent.getActivity(
            this, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("DSH 已连接网关")
            .setContentText("正在后台监听新事件")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentIntent(pi)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "dsh_keepalive"
        private const val NOTIFICATION_ID = 1001
    }
}