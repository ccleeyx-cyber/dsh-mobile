package com.example.dsh_mobile

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/**
 * 桌面小组件（v1.35 / 3.5）。
 *
 * 设计边界（与 Dart 侧 WidgetBridge 的注释一致）：
 *  * **只读**：显示"有没有活要处理"，不在部件上执行批准 —— 部件没有展示命令
 *    原文的位置，一次误触的代价不对称。
 *  * **数据由 Flutter 推**：连接态、会话、待审批都活在 Dart 侧，原生自己拉一遍
 *    必然与 App 内显示不一致。
 *  * **没有进程也要能画**：所有数据落在 SharedPreferences，部件在 App 进程未启动
 *    时（系统广播 onUpdate）照样显示上次的快照，并标注"最近更新"。
 */
class StatusWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(id, buildViews(context))
        }
    }

    companion object {
        const val PREFS = "dsh_widget"

        /** Dart 侧推来一份快照：落盘后刷新所有部件实例。 */
        fun save(context: Context, data: Map<*, *>) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            prefs.edit()
                .putString("title", data["title"]?.toString() ?: "")
                .putString("status", data["status"]?.toString() ?: "")
                .putString("context", data["context"]?.toString() ?: "")
                .putInt("approvals", (data["approvals"] as? Number)?.toInt() ?: 0)
                .putLong("updatedAt", System.currentTimeMillis())
                .apply()
            refreshAll(context)
        }

        fun clear(context: Context) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
            refreshAll(context)
        }

        fun refreshAll(context: Context) {
            val mgr = AppWidgetManager.getInstance(context)
            val ids = mgr.getAppWidgetIds(ComponentName(context, StatusWidgetProvider::class.java))
            for (id in ids) {
                mgr.updateAppWidget(id, buildViews(context))
            }
        }

        private fun buildViews(context: Context): RemoteViews {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val title = prefs.getString("title", "") ?: ""
            val status = prefs.getString("status", "未连接") ?: "未连接"
            val contextPct = prefs.getString("context", "") ?: ""
            val approvals = prefs.getInt("approvals", 0)

            val views = RemoteViews(context.packageName, R.layout.widget_status)
            views.setTextViewText(R.id.widget_title, title.ifBlank { "DSH Mobile" })
            views.setTextViewText(
                R.id.widget_status,
                if (approvals > 0) "$status · $approvals 项待审批" else status
            )
            views.setTextViewText(
                R.id.widget_meta,
                if (contextPct.isBlank()) "点按打开 App" else "上下文 $contextPct"
            )

            // 整块点击 = 打开 App。待审批时 App 会自己弹出审批 dock，
            // 这里不区分 —— 部件位置小，多一个热点只会增加误触。
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (launch != null) {
                launch.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                val pi = PendingIntent.getActivity(
                    context, 0, launch,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                views.setOnClickPendingIntent(R.id.widget_root, pi)
            }
            return views
        }
    }
}
