window.__ModuleLoader__.load({
  id: "dsh-mobile-bridge",
  factory: (require) => {
    var module = { exports: {} };
    var exports = module.exports;
    var React = require("react");
    var { createElement: h, useCallback, useEffect, useState } = React;

    const RPC_CHANNEL = '/dsh-mobile-bridge';
    const ENDPOINTS = {
      getConfig: 'config/get',
      updateConfig: 'config/update',
      generateToken: 'token/generate'
    };

    const S = {
      container: { display: 'flex', flexDirection: 'column', gap: 16, maxWidth: 680, paddingBottom: 32 },
      card: { background: 'var(--dsw-alias-bg-layer-1, #ffffff)', border: '1px solid var(--dsw-alias-border-l2, #e5e7eb)', borderRadius: 10, padding: '18px 20px', boxShadow: '0 1px 3px rgba(0,0,0,0.03)' },
      header: { display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 6 },
      title: { fontSize: 16, fontWeight: 600, color: 'var(--dsw-alias-label-primary, #111827)' },
      subtitle: { color: 'var(--dsw-alias-label-tertiary, #6b7280)', fontSize: 12, lineHeight: 1.5 },
      badgeSuccess: { fontSize: 11, padding: '3px 9px', borderRadius: 999, background: '#ecfdf5', color: '#059669', border: '1px solid #a7f3d0', fontWeight: 500, display: 'inline-flex', alignItems: 'center', gap: 4 },
      grid: { display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: 12, marginTop: 14, marginBottom: 8 },
      metricCard: { background: 'var(--dsw-alias-bg-layer-2, #f9fafb)', border: '1px solid var(--dsw-alias-border-l3, #f3f4f6)', borderRadius: 8, padding: '12px 14px' },
      metricLabel: { fontSize: 11, color: 'var(--dsw-alias-label-tertiary, #6b7280)', marginBottom: 4 },
      metricValue: { fontSize: 13, fontWeight: 600, color: 'var(--dsw-alias-label-primary, #111827)', wordBreak: 'break-all', fontFamily: 'ui-monospace,SFMono-Regular,Consolas,monospace' },
      formGroup: { display: 'flex', flexDirection: 'column', gap: 6, marginBottom: 14 },
      label: { fontSize: 13, fontWeight: 500, color: 'var(--dsw-alias-label-primary, #374151)' },
      helpText: { fontSize: 11, color: 'var(--dsw-alias-label-tertiary, #6b7280)' },
      inputRow: { display: 'flex', gap: 8, alignItems: 'center' },
      input: { font: 'inherit', fontSize: 13, padding: '7px 10px', borderRadius: 6, border: '1px solid var(--dsw-alias-border-l2, #d1d5db)', background: 'var(--dsw-alias-bg-layer-1, #fff)', color: 'var(--dsw-alias-label-primary, #111827)', outline: 'none', width: '100%', boxSizing: 'border-box' },
      primaryBtn: { font: 'inherit', cursor: 'pointer', border: 'none', background: '#0078D4', color: '#ffffff', height: 32, padding: '0 16px', borderRadius: 6, fontSize: 13, fontWeight: 500, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 6, textDecoration: 'none', boxShadow: '0 1px 2px rgba(0,120,212,0.2)' },
      btn: { font: 'inherit', cursor: 'pointer', border: '1px solid var(--dsw-alias-border-l2, #d1d5db)', background: 'var(--dsw-alias-bg-layer-1, #fff)', color: 'var(--dsw-alias-label-primary, #374151)', height: 32, padding: '0 12px', borderRadius: 6, fontSize: 12, fontWeight: 500, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 4, textDecoration: 'none', flexShrink: 0 },
      btnSuccess: { font: 'inherit', border: '1px solid #a7f3d0', background: '#ecfdf5', color: '#059669', height: 32, padding: '0 12px', borderRadius: 6, fontSize: 12, fontWeight: 500, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 4 },
      noticeBox: { background: '#f0f7ff', border: '1px solid #cce4ff', borderRadius: 8, padding: '10px 14px', fontSize: 12, color: '#004c87', lineHeight: 1.5, marginTop: 10 }
    };

    function MobileBridgeTab({ rpcCall }) {
      const [config, setConfig] = useState(null);
      const [token, setToken] = useState('');
      const [port, setPort] = useState(3088);
      const [npsHost, setNpsHost] = useState('n.cnm.asia');
      const [npsPort, setNpsPort] = useState(3088);
      const [useHttps, setUseHttps] = useState(false);
      const [showToken, setShowToken] = useState(false);
      const [saving, setSaving] = useState(false);
      const [saveMessage, setSaveMessage] = useState('');
      const [error, setError] = useState('');
      const [copiedKey, setCopiedKey] = useState('');

      const call = useCallback(async (endpoint, payload) => {
        const res = await rpcCall(endpoint, payload);
        if (!res?.ok) throw new Error(res?.error?.message ?? 'RPC 调用失败');
        return res.value;
      }, [rpcCall]);

      const load = useCallback(async () => {
        try {
          const cfg = await call(ENDPOINTS.getConfig, {});
          setConfig(cfg);
          setToken(cfg.token || 'DSH_SECURE_TOKEN_2026');
          setPort(cfg.port || 3088);
          setNpsHost(cfg.npsHost || 'n.cnm.asia');
          setNpsPort(cfg.npsPort || 3088);
          setUseHttps(Boolean(cfg.useHttps));
          setError('');
        } catch (e) {
          setError(e.message);
        }
      }, [call]);

      useEffect(() => {
        load();
      }, [load]);

      const handleSave = async () => {
        setSaving(true);
        setSaveMessage('');
        setError('');
        try {
          const res = await call(ENDPOINTS.updateConfig, {
            token: token.trim(),
            port: Number(port) || 3088,
            npsHost: npsHost.trim(),
            npsPort: Number(npsPort) || 3088,
            useHttps
          });
          setConfig((prev) => ({ ...prev, ...res.config, ...res }));
          setSaveMessage('✅ 配置已成功保存并立即生效！');
          setTimeout(() => setSaveMessage(''), 3000);
        } catch (e) {
          setError('保存失败: ' + e.message);
        } finally {
          setSaving(false);
        }
      };

      const handleGenerateToken = async () => {
        try {
          const res = await call(ENDPOINTS.generateToken, {});
          if (res?.token) {
            setToken(res.token);
            setShowToken(true);
          }
        } catch (e) {
          setError('生成密钥失败: ' + e.message);
        }
      };

      const copyText = async (text, key) => {
        try {
          await navigator.clipboard.writeText(text);
          setCopiedKey(key);
          setTimeout(() => setCopiedKey(''), 2500);
        } catch {
          setError('复制失败，请手动选择复制');
        }
      };

      const copyFullConfig = () => {
        const text = `Host: ${npsHost}\nPort: ${npsPort}\nToken: ${token}`;
        copyText(text, 'fullConfig');
      };

      const npsScheme = useHttps ? 'https' : 'http';
      const npsApkUrl = `${npsScheme}://${npsHost}:${npsPort}/dsh-agent.apk`;
      const localApkUrl = `http://${config?.localIp || '127.0.0.1'}:${port}/dsh-agent.apk`;

      return h('div', { style: S.container },
        // 1. 状态卡片
        h('div', { style: S.card },
          h('div', { style: S.header },
            h('div', { style: S.title }, '📱 移动终端网关 (DSH Mobile Bridge)'),
            h('span', { style: S.badgeSuccess },
              h('span', { style: { width: 6, height: 6, borderRadius: '50%', background: '#059669', display: 'inline-block' } }),
              `网关运行中 · 端口 ${port}`
            ),
          ),
          h('div', { style: S.subtitle },
            '原生运行于 DSH 进程内，为 Android 客户端 (DSH Mobile) 提供安全鉴权、会话实时双工流式中继与工具审批。'
          ),
        ),

        // 2. 核心设置卡片 (授权码 / 端口 / NPS)
        h('div', { style: S.card },
          h('div', { style: S.header },
            h('div', { style: S.title }, '🔐 网关连接与安全授权设置'),
          ),
          h('div', { style: { ...S.subtitle, marginBottom: 16 } },
            '在此配置手机连接使用的安全授权码（Token）、本地监听端口以及 NPS 穿透地址。'
          ),

          // 授权码设置
          h('div', { style: S.formGroup },
            h('label', { style: S.label }, '访问授权码 (Auth Token / Key)'),
            h('div', { style: S.inputRow },
              h('input', {
                type: showToken ? 'text' : 'password',
                value: token,
                onChange: (e) => setToken(e.target.value),
                style: { ...S.input, fontFamily: 'ui-monospace,SFMono-Regular,Consolas,monospace' },
                placeholder: '请输入授权码，例如: DSH_SECURE_TOKEN_2026'
              }),
              h('button', {
                type: 'button',
                style: S.btn,
                onClick: () => setShowToken(!showToken)
              }, showToken ? '隐藏' : '显示'),
              h('button', {
                type: 'button',
                style: S.btn,
                onClick: handleGenerateToken
              }, '🎲 随机生成'),
              h('button', {
                type: 'button',
                style: copiedKey === 'token' ? S.btnSuccess : S.btn,
                onClick: () => copyText(token, 'token')
              }, copiedKey === 'token' ? '已复制' : '复制')
            ),
            h('span', { style: S.helpText }, '手机 App 首次连接或重新连接时需填入此授权码，支持自定义任意字符串。')
          ),

          // 本地监听端口
          h('div', { style: S.formGroup },
            h('label', { style: S.label }, '本地网关监听端口 (Port)'),
            h('input', {
              type: 'number',
              value: port,
              onChange: (e) => setPort(e.target.value),
              style: { ...S.input, maxWidth: 200 },
              placeholder: '3088'
            }),
            h('span', { style: S.helpText }, 'DSH 进程内启动的移动网关端口，默认 3088。')
          ),

          // NPS 穿透地址与端口
          h('div', { style: { display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 12, marginBottom: 14 } },
            h('div', { style: S.formGroup },
              h('label', { style: S.label }, 'NPS 穿透地址 (Host / Domain)'),
              h('input', {
                type: 'text',
                value: npsHost,
                onChange: (e) => setNpsHost(e.target.value),
                style: S.input,
                placeholder: 'n.cnm.asia'
              }),
              h('span', { style: S.helpText }, 'NPS 穿透服务域名或公网 IP，例如 n.cnm.asia。')
            ),
            h('div', { style: S.formGroup },
              h('label', { style: S.label }, 'NPS 外网端口 (Port)'),
              h('input', {
                type: 'number',
                value: npsPort,
                onChange: (e) => setNpsPort(e.target.value),
                style: S.input,
                placeholder: '3088'
              }),
              h('span', { style: S.helpText }, 'NPS 穿透映射的外网端口。')
            )
          ),

          // 保存按钮
          h('div', { style: { display: 'flex', alignItems: 'center', gap: 12, marginTop: 8 } },
            h('button', {
              type: 'button',
              style: S.primaryBtn,
              disabled: saving,
              onClick: handleSave
            }, saving ? '正在保存...' : '💾 保存配置'),
            saveMessage ? h('span', { style: { fontSize: 13, color: '#059669', fontWeight: 500 } }, saveMessage) : null
          )
        ),

        // 3. 手机端连接参数速览
        h('div', { style: S.card },
          h('div', { style: S.header },
            h('div', { style: S.title }, '📲 手机客户端连接配置'),
            h('button', {
              type: 'button',
              style: copiedKey === 'fullConfig' ? S.btnSuccess : S.btn,
              onClick: copyFullConfig
            }, copiedKey === 'fullConfig' ? '已复制全套参数' : '📋 一键复制全部参数')
          ),
          h('div', { style: S.subtitle },
            '在手机端 DSH Mobile App「连接配置」页中填入以下参数即可一键连接：'
          ),

          h('div', { style: S.grid },
            h('div', { style: S.metricCard },
              h('div', { style: S.metricLabel }, '公网穿透 Host'),
              h('div', { style: S.metricValue }, npsHost || 'n.cnm.asia'),
            ),
            h('div', { style: S.metricCard },
              h('div', { style: S.metricLabel }, '公网穿透 Port'),
              h('div', { style: S.metricValue }, String(npsPort || 3088)),
            ),
            h('div', { style: S.metricCard },
              h('div', { style: S.metricLabel }, '授权码 (Token)'),
              h('div', { style: S.metricValue }, token || 'DSH_SECURE_TOKEN_2026'),
            ),
            h('div', { style: S.metricCard },
              h('div', { style: S.metricLabel }, '局域网 Host (本地测试)'),
              h('div', { style: S.metricValue }, config?.localIp || '127.0.0.1'),
            ),
          ),
        ),

        // 4. Android APK 下载
        h('div', { style: S.card },
          h('div', { style: S.header },
            h('div', { style: S.title }, '📦 Android APK 客户端安装包 (v1.2.8)'),
            h('a', {
              href: npsApkUrl,
              target: '_blank',
              style: S.primaryBtn
            }, '📥 立即下载 APK')
          ),
          h('div', { style: S.subtitle },
            '最新构建的 Fluent Design 2 正式版客户端，支持流畅空会话、深度会话隔离与实时思考流。'
          ),
          h('div', { style: { marginTop: 12, display: 'flex', flexDirection: 'column', gap: 8 } },
            h('div', { style: { display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '8px 12px', background: 'var(--dsw-alias-bg-layer-2, #f9fafb)', borderRadius: 6, fontSize: 12 } },
              h('span', { style: { fontFamily: 'monospace', color: 'var(--dsw-alias-label-secondary, #4b5563)' } }, `公网下载: ${npsApkUrl}`),
              h('button', {
                type: 'button',
                style: copiedKey === 'npsApk' ? S.btnSuccess : S.btn,
                onClick: () => copyText(npsApkUrl, 'npsApk')
              }, copiedKey === 'npsApk' ? '已复制' : '复制链接')
            ),
            h('div', { style: { display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '8px 12px', background: 'var(--dsw-alias-bg-layer-2, #f9fafb)', borderRadius: 6, fontSize: 12 } },
              h('span', { style: { fontFamily: 'monospace', color: 'var(--dsw-alias-label-secondary, #4b5563)' } }, `局域网下载: ${localApkUrl}`),
              h('button', {
                type: 'button',
                style: copiedKey === 'localApk' ? S.btnSuccess : S.btn,
                onClick: () => copyText(localApkUrl, 'localApk')
              }, copiedKey === 'localApk' ? '已复制' : '复制链接')
            )
          )
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
