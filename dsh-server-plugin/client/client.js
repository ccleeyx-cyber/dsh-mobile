window.__ModuleLoader__.load({
  id: "dsh-mobile-bridge",
  factory: (require) => {
    var module = { exports: {} };
    var exports = module.exports;
    var React = require("react");
    var { createElement: h, useCallback, useEffect, useState } = React;

    const RPC_CHANNEL = '/dsh-mobile-bridge';
    const ENDPOINTS = {
      status: 'status',
      beginPair: 'pair/begin',
      devices: 'devices/list',
      revoke: 'devices/revoke',
      setRole: 'devices/role',
      audit: 'audit/list',
      rotate: 'devices/rotate'
    };

    function ago(ts) {
      if (!ts) return '从未';
      const diff = Date.now() - ts;
      if (diff < 60000) return '刚刚';
      if (diff < 3600000) return `${Math.floor(diff / 60000)} 分钟前`;
      if (diff < 86400000) return `${Math.floor(diff / 3600000)} 小时前`;
      return `${Math.floor(diff / 86400000)} 天前`;
    }

    const S = {
      container: { display: 'flex', flexDirection: 'column', gap: 16, maxWidth: 680, paddingBottom: 24 },
      card: { background: 'var(--dsw-alias-bg-layer-1, #ffffff)', border: '1px solid var(--dsw-alias-border-l2, #e5e7eb)', borderRadius: 12, padding: '16px 20px', boxShadow: '0 1px 3px rgba(0,0,0,0.03)' },
      header: { display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 4 },
      title: { fontSize: 16, fontWeight: 600, color: 'var(--dsw-alias-label-primary, #111827)' },
      subtitle: { color: 'var(--dsw-alias-label-tertiary, #6b7280)', fontSize: 12, lineHeight: 1.5 },
      badgeSuccess: { fontSize: 11, padding: '3px 9px', borderRadius: 999, background: '#ecfdf5', color: '#059669', border: '1px solid #a7f3d0', fontWeight: 500 },
      badgeDanger: { fontSize: 11, padding: '3px 9px', borderRadius: 999, background: '#fef2f2', color: '#dc2626', border: '1px solid #fecaca', fontWeight: 500 },
      grid: { display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(130px, 1fr))', gap: 12, marginTop: 14, marginBottom: 8 },
      metricCard: { background: 'var(--dsw-alias-bg-layer-2, #f9fafb)', border: '1px solid var(--dsw-alias-border-l3, #f3f4f6)', borderRadius: 8, padding: '10px 12px' },
      metricLabel: { fontSize: 11, color: 'var(--dsw-alias-label-tertiary, #6b7280)', marginBottom: 4 },
      metricValue: { fontSize: 14, fontWeight: 600, color: 'var(--dsw-alias-label-primary, #111827)' },
      row: { display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8, padding: '8px 0' },
      primaryBtn: { font: 'inherit', cursor: 'pointer', border: 'none', background: '#0078D4', color: '#ffffff', height: 32, padding: '0 16px', borderRadius: 6, fontSize: 13, fontWeight: 500, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 6, textDecoration: 'none', boxShadow: '0 1px 2px rgba(0,120,212,0.2)' },
      btn: { font: 'inherit', cursor: 'pointer', border: '1px solid var(--dsw-alias-border-l2, #d1d5db)', background: 'var(--dsw-alias-bg-layer-1, #fff)', color: 'var(--dsw-alias-label-primary, #374151)', height: 28, padding: '0 10px', borderRadius: 6, fontSize: 12, fontWeight: 500, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 4, textDecoration: 'none' },
      btnDanger: { font: 'inherit', cursor: 'pointer', border: '1px solid #fecaca', background: '#fff5f5', color: '#dc2626', height: 28, padding: '0 10px', borderRadius: 6, fontSize: 12, fontWeight: 500 },
      code: { fontFamily: 'ui-monospace,SFMono-Regular,Consolas,monospace', fontSize: 28, letterSpacing: 6, fontWeight: 700, color: '#0078D4', margin: '10px 0', background: '#f0f7ff', display: 'inline-block', padding: '6px 18px', borderRadius: 8, border: '1px solid #cce4ff' },
      tag: { fontSize: 11, padding: '2px 8px', borderRadius: 999, border: '1px solid var(--dsw-alias-border-l2, #d1d5db)', background: 'var(--dsw-alias-bg-layer-2, #f9fafb)' },
      noticeBox: { background: '#f0f7ff', border: '1px solid #cce4ff', borderRadius: 8, padding: '10px 14px', fontSize: 12, color: '#004c87', lineHeight: 1.5, marginTop: 10 }
    };

    function MobileBridgeTab({ rpcCall }) {
      const [status, setStatus] = useState(null);
      const [devices, setDevices] = useState([]);
      const [pair, setPair] = useState(null);
      const [audit, setAudit] = useState([]);
      const [error, setError] = useState('');
      const [copiedInfo, setCopiedInfo] = useState('');
      const [tick, setTick] = useState(0);

      const call = useCallback(async (endpoint, payload) => {
        const res = await rpcCall(endpoint, payload);
        if (!res?.ok) throw new Error(res?.error?.message ?? 'RPC 调用失败');
        return res.value;
      }, [rpcCall]);

      const refresh = useCallback(async () => {
        try {
          const [s, d, a] = await Promise.all([
            call(ENDPOINTS.status, {}),
            call(ENDPOINTS.devices, {}),
            call(ENDPOINTS.audit, { limit: 40 }),
          ]);
          setStatus(s);
          setDevices(d);
          setAudit(a);
          setError('');
        } catch (e) {
          setError(e.message);
        }
      }, [call]);

      useEffect(() => {
        refresh();
        const t = setInterval(refresh, 5000);
        return () => clearInterval(t);
      }, [refresh]);

      useEffect(() => {
        const t = setInterval(() => setTick((n) => n + 1), 1000);
        return () => clearInterval(t);
      }, []);

      const copyToClipboard = async (text, label) => {
        try {
          await navigator.clipboard.writeText(text);
          setCopiedInfo(`已复制${label}`);
          setTimeout(() => setCopiedInfo(''), 2500);
        } catch {
          setCopiedInfo('复制失败，请手动选择复制');
        }
      };

      const beginPair = async () => {
        try {
          const p = await call(ENDPOINTS.beginPair, {});
          setPair(p);
          setError('');
        } catch (e) {
          setError(e.message);
        }
      };

      const revoke = async (id) => {
        try {
          await call(ENDPOINTS.revoke, { id });
          await refresh();
        } catch (e) {
          setError(e.message);
        }
      };

      const toggleRole = async (d) => {
        try {
          await call(ENDPOINTS.setRole, { id: d.id, role: d.role === 'readwrite' ? 'readonly' : 'readwrite' });
          await refresh();
        } catch (e) {
          setError(e.message);
        }
      };

      const rotate = async (id) => {
        try {
          const r = await call(ENDPOINTS.rotate, { id });
          setError(`新令牌（请在手机端重新配对或粘贴）：${r.token}`);
          await refresh();
        } catch (e) {
          setError(e.message);
        }
      };

      const remain = pair ? Math.max(0, Math.ceil((pair.expiresAt - Date.now()) / 1000)) : 0;
      const isRunning = status?.running;
      const apkDownloadUrl = `http://127.0.0.1:${status?.port || 3088}/dsh-agent.apk`;
      const npsUrl = 'http://n.cnm.asia:3088';

      return h('div', { style: S.container },
        // 1. 运行状态
        h('div', { style: S.card },
          h('div', { style: S.header },
            h('div', { style: S.title }, '移动终端管理 (DSH Mobile Bridge)'),
            h('span', { style: isRunning ? S.badgeSuccess : S.badgeDanger },
              isRunning ? 'DSH 原生服务运行中' : '网关未启动'
            ),
          ),
          h('div', { style: S.subtitle },
            '作为 DSH 原生插件运行，直连内部 MUX 核心，安全托管移动端流式交互与 APK 安装包。'
          ),
          h('div', { style: S.grid },
            h('div', { style: S.metricCard },
              h('div', { style: S.metricLabel }, '移动端端口'),
              h('div', { style: S.metricValue }, `:${status?.port ?? 3088}`),
            ),
            h('div', { style: S.metricCard },
              h('div', { style: S.metricLabel }, 'DSH 核心端口'),
              h('div', { style: S.metricValue }, `:${status?.dshPort ?? 3080}`),
            ),
            h('div', { style: S.metricCard },
              h('div', { style: S.metricLabel }, '已配对设备'),
              h('div', { style: S.metricValue }, `${status?.paired ?? devices.filter(d => !d.revoked).length} 台`),
            ),
            h('div', { style: S.metricCard },
              h('div', { style: S.metricLabel }, '在线活跃连接'),
              h('div', { style: S.metricValue }, `${status?.connectedClients ?? 0} 个`),
            ),
          ),
          h('div', { style: S.noticeBox },
            h('div', { style: { fontWeight: 600, marginBottom: 2 } }, '🌐 NPS 公网隧道与移动端配置'),
            h('div', null,
              '公网连接地址：',
              h('strong', null, npsUrl),
              '（手机端配置时填入此地址，即可实现公网远程访问）。',
            ),
            copiedInfo ? h('div', { style: { color: '#059669', fontWeight: 600, marginTop: 4 } }, copiedInfo) : null,
          ),
        ),

        // 2. 安装包下载
        h('div', { style: S.card },
          h('div', { style: S.header },
            h('div', { style: { fontSize: 15, fontWeight: 600 } }, '📱 Android 客户端 (DSH Mobile)'),
            h('span', { style: S.tag }, status?.apkVersion ? `v${status.apkVersion}` : 'v1.2.7'),
          ),
          h('div', { style: S.subtitle },
            'Fluent Design 风格、支持实时流式思考过程、工作区切换、清爽空会话与审批确认。'
          ),
          h('div', { style: { display: 'flex', gap: 10, marginTop: 14, flexWrap: 'wrap' } },
            h('a', {
              href: apkDownloadUrl,
              download: 'dsh-agent.apk',
              target: '_blank',
              rel: 'noopener noreferrer',
              style: S.primaryBtn,
            }, '⬇️ 立即下载安装包 (APK)'),
            h('button', {
              style: S.btn,
              onClick: () => copyToClipboard(`${npsUrl}/dsh-agent.apk`, '公网下载链接'),
            }, '📋 复制公网 APK 直链'),
            h('button', {
              style: S.btn,
              onClick: () => copyToClipboard(npsUrl, 'NPS 服务器连接地址'),
            }, '📋 复制 NPS 连接地址'),
          ),
        ),

        // 3. 配对新手机
        h('div', { style: S.card },
          h('div', { style: { fontSize: 15, fontWeight: 600, marginBottom: 4 } }, '🔑 配对新手机'),
          h('div', { style: S.subtitle },
            '生成 6 位安全配对码，在手机端登录时输入，一次性安全握手并完成设备绑定。'
          ),
          pair && remain > 0
            ? h('div', { style: { marginTop: 12, textAlign: 'center', background: 'var(--dsw-alias-bg-layer-2, #fafafa)', padding: 16, borderRadius: 8 } },
                h('div', { style: { fontSize: 13, color: 'var(--dsw-alias-label-secondary, #4b5563)' } },
                  '请在手机 App 登录页中输入以下 6 位配对码：'
                ),
                h('div', { style: S.code }, pair.code),
                h('div', { style: { fontSize: 12, color: '#dc2626', fontWeight: 500 } },
                  `⏱️ 剩余有效时间：${remain} 秒`
                ),
                h('div', { style: { marginTop: 10 } },
                  h('button', {
                    style: S.btn,
                    onClick: () => copyToClipboard(pair.code, '配对码'),
                  }, '复制配对码'),
                ),
              )
            : h('div', { style: { marginTop: 12 } },
                h('button', { style: S.primaryBtn, onClick: beginPair }, '⚡ 生成 6 位配对码 (5 分钟有效)'),
              ),
        ),

        // 4. 设备列表
        h('div', { style: S.card },
          h('div', { style: { fontSize: 15, fontWeight: 600, marginBottom: 4 } }, '💻 已配对移动设备'),
          h('div', { style: S.subtitle }, '管理当前已授权访问的移动设备，可随时撤销访问或修改读写权限。'),
          devices.length === 0
            ? h('div', { style: { ...S.subtitle, marginTop: 12, padding: '12px 0' } }, '暂无已配对设备。请生成配对码并在手机端绑定。')
            : h('div', { style: { marginTop: 8 } },
                devices.map((d) => h('div', {
                  key: d.id,
                  style: {
                    ...S.row,
                    borderBottom: '1px solid var(--dsw-alias-border-l3, #f3f4f6)',
                    padding: '10px 0',
                  },
                },
                  h('div', { style: { minWidth: 0 } },
                    h('div', { style: { fontWeight: 600, fontSize: 13 } },
                      d.name || '移动终端',
                      d.revoked ? h('span', { style: { ...S.tag, color: '#dc2626', background: '#fef2f2', marginLeft: 8 } }, '已撤销') : null,
                      h('span', { style: { ...S.tag, marginLeft: 6, color: d.role === 'readwrite' ? '#059669' : '#d97706' } },
                        d.role === 'readwrite' ? '读写' : '只读'
                      ),
                    ),
                    h('div', { style: { ...S.subtitle, marginTop: 4 } },
                      `${d.platform} · 最近活跃: ${ago(d.lastSeenAt)} · 连接 ${d.connectCount || 0} 次${d.lastIp ? ` · IP: ${d.lastIp}` : ''}`
                    ),
                  ),
                  h('div', { style: { display: 'flex', gap: 6, flexShrink: 0 } },
                    h('button', {
                      style: S.btn,
                      onClick: () => toggleRole(d),
                    }, d.role === 'readwrite' ? '设为只读' : '设为读写'),
                    h('button', {
                      style: S.btn,
                      onClick: () => rotate(d.id),
                    }, '换令牌'),
                    d.revoked ? null : h('button', {
                      style: S.btnDanger,
                      onClick: () => revoke(d.id),
                    }, '撤销权限'),
                  ),
                )),
              ),
        ),

        // 5. 审计记录
        h('div', { style: S.card },
          h('div', { style: { fontSize: 15, fontWeight: 600, marginBottom: 4 } }, '🛡️ 访问审计日志'),
          h('div', { style: S.subtitle }, '记录最近 40 条移动端连接、握手、指令与权限变更事件。'),
          audit.length === 0
            ? h('div', { style: { ...S.subtitle, marginTop: 12 } }, '暂无审计记录。')
            : h('div', {
                style: {
                  marginTop: 10,
                  maxHeight: 220,
                  overflowY: 'auto',
                  background: 'var(--dsw-alias-bg-layer-2, #fafafa)',
                  borderRadius: 8,
                  padding: 10,
                  border: '1px solid var(--dsw-alias-border-l3, #f3f4f6)',
                },
              },
                audit.map((row, i) => h('div', {
                  key: i,
                  style: {
                    fontFamily: 'ui-monospace,SFMono-Regular,Consolas,monospace',
                    fontSize: 11,
                    color: 'var(--dsw-alias-label-secondary, #4b5563)',
                    padding: '3px 0',
                    borderBottom: i < audit.length - 1 ? '1px dashed #e5e7eb' : 'none',
                  },
                },
                  `${new Date(row.at).toLocaleTimeString()}  [${row.action}]  ${row.path ?? ''}  ${row.deviceId ?? ''}  ${row.reason ?? ''}`
                )),
              ),
        ),

        error ? h('div', {
          style: { background: '#fef2f2', border: '1px solid #fecaca', borderRadius: 8, padding: '10px 14px', color: '#b91c1c', fontSize: 13 },
        }, error) : null,
      );
    }

    function apply(ctx) {
      const rpcCall = (endpoint, payload, signal) =>
        ctx.connection.rpc.call(RPC_CHANNEL, endpoint, payload, signal);

      ctx.slots.inject('settings.section', () =>
        ctx.slots.register(
          {
            name: 'settings.section',
            id: 'mobile-bridge',
            order: 2,
            label: () => '移动终端',
            inject: () => ({ rpcCall }),
          },
          MobileBridgeTab,
        ),
      );
    }

    module.exports = {
      name: 'dsh-mobile-bridge',
      inject: ['slots', 'connection'],
      apply
    };

    return module.exports;
  }
});
