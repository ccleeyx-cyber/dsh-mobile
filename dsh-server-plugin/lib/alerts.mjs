// dsh-server-plugin 告警引擎（v1.35 / 任务 3.3）
//
// 目标：把「必须打开 App 才能发现问题」变成「问题自己找上门」。
//
// 规则是**网关侧已有数据源**，不新增观测点：
//   turn_error     回合失败（turn/end.reason 的既有解析）
//   context_high   上下文占用过高（会话统计里的上下文比例）
//   heartbeat_lost 上游引擎连接丢失（MUX 关闭）
//   job_failed     后台作业失败（jobs 事件）
//
// 两条纪律：
//   1. **去重窗口**：同一规则同一会话 10 分钟内只报一次。手机收到 20 条「回合
//      失败」只会让人关掉通知，等于把告警能力自己关死。
//   2. **分级**：warning 只进收件箱，critical 才推送。推送是打扰，得留给真正
//      需要立刻处理的事情。
//
// 状态落 `mobile-access/alerts-state.json`，上限 200 条（老的自然淘汰）。
// 时钟与推送都可注入，便于 hermetic 测试。

import fs from 'node:fs';
import path from 'node:path';

export const ALERT_DEDUPE_MS = 10 * 60 * 1000;
export const ALERT_MAX_ENTRIES = 200;

/** 规则 → 严重级与标题。未知规则按 warning 处理。 */
export const ALERT_RULES = Object.freeze({
  turn_error: { severity: 'warning', title: '会话回合失败' },
  context_high: { severity: 'warning', title: '上下文占用过高' },
  heartbeat_lost: { severity: 'critical', title: '引擎连接丢失' },
  job_failed: { severity: 'critical', title: '后台作业失败' }
});

export function ruleMeta(rule) {
  return ALERT_RULES[rule] || { severity: 'warning', title: String(rule || '未知事件') };
}

/**
 * @param {object} opts
 * @param {string|null} opts.stateFile 落盘路径；null = 仅内存（测试）
 * @param {() => number} opts.now 注入时钟
 * @param {(alert: object) => void} opts.push critical 级推送
 */
export function createAlertEngine({
  stateFile = null,
  now = () => Date.now(),
  dedupeMs = ALERT_DEDUPE_MS,
  maxEntries = ALERT_MAX_ENTRIES,
  push = null,
  logger = console
} = {}) {
  /** @type {Array<{id:string, rule:string, severity:string, title:string, sessionId:string, message:string, createdAt:number, readAt:number|null}>} */
  let alerts = [];
  const lastFired = new Map();
  let seq = 0;

  function load() {
    if (!stateFile) return;
    try {
      const raw = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
      if (Array.isArray(raw?.alerts)) {
        alerts = raw.alerts.filter((a) => a && typeof a.id === 'string').slice(-maxEntries);
      }
    } catch { /* 缺文件 / 坏 JSON：从空开始，不阻断启动 */ }
  }

  function persist() {
    if (!stateFile) return;
    try {
      fs.mkdirSync(path.dirname(stateFile), { recursive: true });
      fs.writeFileSync(stateFile, JSON.stringify({ alerts, updatedAt: now() }, null, 2), 'utf8');
    } catch (err) {
      logger.warn?.('[alerts] 落盘失败: %s', err?.message || err);
    }
  }

  load();

  return {
    /**
     *  ingested 一条事件。
     * @returns 新产生的告警；被去重/被丢弃时返回 null
     */
    ingest({ rule, sessionId = '', message = '', detail = null } = {}) {
      const key = String(rule || '').trim();
      if (!key) return null;
      const meta = ruleMeta(key);
      const sessionKey = `${key}:${sessionId || '-'}`;
      const t = now();
      // 从未报过 → 不参与去重。用 -Infinity 而不是 0：时钟可以被注入成 0
      // （测试用），`t - 0 < dedupeMs` 会把第一次告警也吞掉。
      const last = lastFired.has(sessionKey) ? lastFired.get(sessionKey) : -Infinity;
      if (t - last < dedupeMs) return null;
      lastFired.set(sessionKey, t);

      const alert = {
        id: `alert_${t}_${seq++}`,
        rule: key,
        severity: meta.severity,
        title: meta.title,
        sessionId: String(sessionId || ''),
        message: String(message || meta.title).slice(0, 400),
        detail: detail && typeof detail === 'object' ? detail : null,
        createdAt: t,
        readAt: null
      };

      alerts.push(alert);
      if (alerts.length > maxEntries) alerts = alerts.slice(-maxEntries);
      persist();

      if (alert.severity === 'critical' && typeof push === 'function') {
        try { push(alert); } catch (err) { logger.warn?.('[alerts] 推送失败: %s', err?.message || err); }
      }
      return alert;
    },

    list({ unreadOnly = false } = {}) {
      const rows = unreadOnly ? alerts.filter((a) => a.readAt == null) : alerts;
      // 新的在前：收件箱里用户先看最近发生的事。
      return rows.slice().reverse();
    },

    get unreadCount() {
      // 用 == null 而不是真假判断：注入时钟为 0 时，readAt=0 会被当成"未读"。
      return alerts.filter((a) => a.readAt == null).length;
    },

    /** 标记已读。传 `all: true` 或 id 数组。返回被标记的数量。 */
    markRead(ids, { all = false } = {}) {
      const t = now();
      let changed = 0;
      const wanted = new Set(Array.isArray(ids) ? ids : []);
      for (const a of alerts) {
        if (a.readAt != null) continue;
        if (all || wanted.has(a.id)) {
          a.readAt = t;
          changed++;
        }
      }
      if (changed > 0) persist();
      return changed;
    },

    /** 测试用：只清内存与去重窗口，不删文件。 */
    _reset() {
      alerts = [];
      lastFired.clear();
      seq = 0;
    },

    get size() { return alerts.length; }
  };
}
