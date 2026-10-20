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
      generateToken: 'token/generate',
      pairQrData: 'pair/qrdata',
      devicesList: 'devices/list',
      devicesRevoke: 'devices/revoke'
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
          // No published default. store.mjs mints a random token on a fresh
          // install, so a missing value here means "not generated yet" — showing
          // the old literal made an unconfigured gateway look configured, and
          // that literal was in every published build.
          setToken(cfg.token || '');
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
      // [cleanup 2026-10-21] 网关不再托管安装包，原先这里还有 npsApkUrl /
      // localApkUrl 两个指向 /dsh-agent.apk 的变量（已是死代码）。安装包只认
      // GitHub Releases。
      const RELEASES_URL = 'https://github.com/ccleeyx-cyber/dsh-mobile/releases';
      // 手机真正在用的公网地址 = NPS 穿透地址（config 里用户自己填的）。
      const publicHost = npsHost;
      const publicPort = npsPort;

      // ---- 扫码配对卡片状态 [feat 2026-10-12] ----
      const [qr, setQr] = useState(null);            // {qrDataUrl, pairCode, host, port, expiresAt, ttlMs}
      const [qrBusy, setQrBusy] = useState(false);
      const [qrError, setQrError] = useState('');
      const [qrCopied, setQrCopied] = useState(false);

      const generateQr = useCallback(async () => {
        setQrBusy(true); setQrError('');
        try {
          const res = await call(ENDPOINTS.pairQrData, {});
          setQr(res);
        } catch (e) {
          setQrError('生成失败: ' + e.message);
        } finally {
          setQrBusy(false);
        }
      }, [call]);

      const qrText = qr ? `Host: ${qr.host}:${qr.port}\n配对码: ${qr.pairCode}\n${qr.ttlMs / 60000 | 0} 分钟内有效` : '';
      const copyQr = () => { copyText(qrText, 'qrText'); setQrCopied(true); setTimeout(() => setQrCopied(false), 2500); };

      // ---- 设备管理卡片状态 ----
      const [devices, setDevices] = useState(null);
      const [devicesError, setDevicesError] = useState('');
      const [revokingId, setRevokingId] = useState('');

      const loadDevices = useCallback(async () => {
        try {
          setDevices(await call(ENDPOINTS.devicesList, {}));
          setDevicesError('');
        } catch (e) {
          setDevicesError('设备列表加载失败: ' + e.message);
        }
      }, [call]);

      useEffect(() => { loadDevices(); }, [loadDevices]);

      const revokeDevice = async (deviceId) => {
        if (!window.confirm('确定移除此设备？被移除的手机下次请求将被拒绝并要求重新配对。')) return;
        setRevokingId(deviceId);
        try {
          await call(ENDPOINTS.devicesRevoke, { deviceId });
          await loadDevices();
        } catch (e) {
          setDevicesError('移除失败: ' + e.message);
        } finally {
          setRevokingId('');
        }
      };

      const fmtTime = (ts) => {
        try { return new Date(ts).toLocaleTimeString(); } catch { return String(ts); }
      };
      const fmtDate = (ts) => {
        try { return new Date(ts).toLocaleString(); } catch { return String(ts); }
      };

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
                placeholder: '请输入授权码 (dsh_ 开头)'
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
              h('div', { style: S.metricValue }, token || '未生成'),
            ),
            h('div', { style: S.metricCard },
              h('div', { style: S.metricLabel }, '局域网 Host (本地测试)'),
              h('div', { style: S.metricValue }, config?.localIp || '127.0.0.1'),
            ),
          ),
        ),

        // 4. 扫码配对 [feat 2026-10-12]
        h('div', { style: S.card },
          h('div', { style: S.header },
            h('div', { style: S.title }, '📷 扫码配对'),
            h('button', {
              type: 'button', style: S.primaryBtn,
              disabled: qrBusy, onClick: generateQr
            }, qrBusy ? '生成中...' : (qr ? '🔄 重新生成' : '生成配对二维码'))
          ),
          h('div', { style: S.subtitle },
            '生成一次性 6 位配对码的二维码（10 分钟有效、5 次错码作废）。手机 App「连接配置」页点「扫码连接」扫描即可自动配对——二维码不含长期凭据，截图留存也只暴露一枚短时配对码。'
          ),
          qr ? h('div', { style: { display: 'flex', gap: 18, marginTop: 14, alignItems: 'flex-start', flexWrap: 'wrap' } },
            qr.qrDataUrl
              ? h('img', { src: qr.qrDataUrl, alt: '配对二维码', style: { width: 180, height: 180, borderRadius: 8, border: '1px solid var(--dsw-alias-border-l2, #e5e7eb)' } })
              : h('div', { style: { width: 180, height: 180, display: 'flex', alignItems: 'center', justifyContent: 'center', textAlign: 'center', fontSize: 12, color: 'var(--dsw-alias-label-tertiary, #6b7280)', border: '1px dashed var(--dsw-alias-border-l2, #d1d5db)', borderRadius: 8 } }, 'qrcode 包不可用\n请手动输入配对码'),
            h('div', { style: { display: 'flex', flexDirection: 'column', gap: 8, minWidth: 220 } },
              h('div', { style: S.metricCard },
                h('div', { style: S.metricLabel }, '配对码（10 分钟内有效）'),
                h('div', { style: { ...S.metricValue, fontSize: 22, letterSpacing: 4 } }, qr.pairCode)
              ),
              h('div', { style: S.metricCard },
                h('div', { style: S.metricLabel }, '二维码里的地址'),
                h('div', { style: S.metricValue }, `${qr.host}:${qr.port}`)
              ),
              (qr.host !== publicHost && publicHost)
                ? h('div', { style: { ...S.noticeBox, marginTop: 0 } },
                    `手机在外面时请手动填公网地址 ${publicHost}:${publicPort}，再用上面的配对码配对（二维码里是局域网地址，出门连不上）。`)
                : null,
              h('div', { style: S.metricCard },
                h('div', { style: S.metricLabel }, '过期时间'),
                h('div', { style: S.metricValue }, fmtTime(qr.expiresAt))
              ),
              h('button', {
                type: 'button', style: qrCopied ? S.btnSuccess : S.btn,
                onClick: copyQr
              }, qrCopied ? '已复制' : '复制配对信息')
            )
          ) : null,
          qrError ? h('div', { style: { ...S.noticeBox, background: '#fef2f2', borderColor: '#fecaca', color: '#b91c1c', marginTop: 12 } }, qrError) : null
        ),

        // 5. 已配对设备管理 [feat 2026-10-12]
        h('div', { style: S.card },
          h('div', { style: S.header },
            h('div', { style: S.title }, '🖥️ 已配对设备'),
            h('button', { type: 'button', style: S.btn, onClick: loadDevices }, '刷新')
          ),
          h('div', { style: S.subtitle },
            '每台配对过的手机一行。被「移除」的设备其凭据立即失效——手机端下次请求会收到下线通知并回到配对页。'
          ),
          devices && devices.length
            ? h('div', { style: { marginTop: 12, display: 'flex', flexDirection: 'column', gap: 6 } },
                devices.map((d) => h('div', {
                  key: d.id || d.deviceId || d.tokenHash,
                  style: { display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '9px 12px', background: 'var(--dsw-alias-bg-layer-2, #f9fafb)', borderRadius: 6, fontSize: 12 }
                },
                  h('div', { style: { display: 'flex', flexDirection: 'column', gap: 2 } },
                    h('span', { style: { fontWeight: 600, color: 'var(--dsw-alias-label-primary, #111827)' } }, `${d.name || '未命名设备'}${d.platform ? ' · ' + d.platform : ''}`),
                    h('span', { style: { color: 'var(--dsw-alias-label-tertiary, #6b7280)' } }, `配对于 ${fmtDate(d.pairedAt || d.createdAt)}`)
                  ),
                  h('button', {
                    type: 'button', style: S.btn,
                    disabled: revokingId === (d.id || d.deviceId),
                    onClick: () => revokeDevice(d.id || d.deviceId)
                  }, revokingId === (d.id || d.deviceId) ? '移除中...' : '移除')
                )))
            : h('div', { style: { ...S.noticeBox, marginTop: 12 } }, devicesError || '还没有设备配对。生成配对二维码，手机扫码即可加入。')
        ),

        // 6. Android APK 下载 —— 只指 GitHub Releases（CI 构建的最新签名包）
        h('div', { style: S.card },
          h('div', { style: S.header },
            h('div', { style: S.title }, '📦 Android APK 客户端安装包'),
            h('a', {
              href: RELEASES_URL,
              target: '_blank',
              style: S.primaryBtn
            }, '📥 前往 GitHub Releases 下载')
          ),
          h('div', { style: S.subtitle },
            'APK 由 GitHub Actions 按每次 push 自动构建并发布到 Releases 页，那里永远是最新版本（v1.15 起：扫码配对、历史无限上翻、一键诊断等）。'
          ),
          h('div', { style: { marginTop: 12, display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '8px 12px', background: 'var(--dsw-alias-bg-layer-2, #f9fafb)', borderRadius: 6, fontSize: 12 } },
            h('span', { style: { fontFamily: 'monospace', color: 'var(--dsw-alias-label-secondary, #4b5563)' } }, RELEASES_URL),
            h('button', {
              type: 'button',
              style: copiedKey === 'releases' ? S.btnSuccess : S.btn,
              onClick: () => copyText(RELEASES_URL, 'releases')
            }, copiedKey === 'releases' ? '已复制' : '复制链接')
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
