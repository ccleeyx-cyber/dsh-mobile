window.__ModuleLoader__.load({
  id: "dsh-mobile-access",
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
      devicesRevoke: 'devices/revoke',
      // [feat 2026-10-21] 远程接入实时状态。这份表与 lib/rpc.mjs 的 ENDPOINTS
      // 是两份拷贝（浏览器侧不能 import 服务端模块），加端点必须两处都改。
      remoteAccess: 'remote-access/status'
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
      // [refactor 2026-10-21] 远程接入：三种 provider **严格互斥**。
      //
      // NPS 与 cloudflared 解决的是同一件事（让手机从公网到达本机），只是一个
      // 用你自己的反向代理、一个由网关自己向外建连。以前它们是两个互不知晓的
      // 功能（NPS 在配置里、cloudflared 的开关在手机上），用户既不知道是二选一，
      // 也会出现"两条出口同时开着、不知道该填哪个地址"。现在只有这一个选择点。
      const [provider, setProvider] = useState('none');
      const [npsHost, setNpsHost] = useState('');
      const [npsPort, setNpsPort] = useState(3088);
      const [useHttps, setUseHttps] = useState(false);
      // [feat 2026-10-21] cloudflared 命名隧道（参考 dsh-pocket）：token 非空即
      // 用 `tunnel run` + 固定域名，地址重启不变；为空则是快速隧道（随机域名）。
      const [cfToken, setCfToken] = useState('');
      const [cfHost, setCfHost] = useState('');
      const [showToken, setShowToken] = useState(false);
      const [saving, setSaving] = useState(false);
      const [saveMessage, setSaveMessage] = useState('');
      const [error, setError] = useState('');
      const [copiedKey, setCopiedKey] = useState('');
      // [feat 2026-10-21] 远程接入的实时状态。provider 在**这一页**选，隧道却是
      // 异步建立的（先拿域名、再连边缘才算 ready），所以必须在这里当场能看见。
      const [raState, setRaState] = useState(null);
      const [raBusy, setRaBusy] = useState(false);

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
          // 远程接入：优先读新模型；旧安装只有 npsHost，按"填了就是 NPS"映射，
          // 与服务端 store.normalizeRemoteAccess 的规则一致。
          const ra = cfg.remoteAccess || null;
          setProvider(ra?.provider || (cfg.npsHost ? 'nps' : 'none'));
          setNpsHost(ra?.nps?.host || cfg.npsHost || '');
          setNpsPort(ra?.nps?.port || cfg.npsPort || 3088);
          setUseHttps(Boolean(ra?.nps?.useHttps ?? cfg.useHttps));
          setCfToken(ra?.cloudflared?.token || '');
          setCfHost(ra?.cloudflared?.host || '');
          setError('');
        } catch (e) {
          setError(e.message);
        }
      }, [call]);

      useEffect(() => {
        load();
      }, [load]);

      const loadRemoteAccess = useCallback(async () => {
        try {
          const st = await call(ENDPOINTS.remoteAccess, {});
          setRaState(st);
          return st;
        } catch {
          // 状态读不到不该打断配置编辑：面板照常可用。
          return null;
        }
      }, [call]);

      useEffect(() => {
        loadRemoteAccess();
      }, [loadRemoteAccess]);

      // 未就绪时自动轮询：点完保存用户会盯着这一屏等结果，让他自己点刷新
      // 等于把"成没成"变成猜谜。
      useEffect(() => {
        if (provider !== 'cloudflared') return undefined;
        if (raState?.ready === true) return undefined;
        const timer = setInterval(() => { loadRemoteAccess(); }, 3000);
        return () => clearInterval(timer);
      }, [provider, raState?.ready, loadRemoteAccess]);

      const handleRefreshRa = async () => {
        setRaBusy(true);
        await loadRemoteAccess();
        setRaBusy(false);
      };

      const providerLabel = (p) => (p === 'nps'
        ? '自有反向代理 (NPS)'
        : p === 'cloudflared'
          ? '临时隧道 (cloudflared)'
          : p === 'none' ? '仅局域网' : '未知');

      const managedLabel = (m) => (m === 'external'
        ? '你的反向代理'
        : m === 'gateway' ? '网关自动建立' : '—');

      const handleSave = async () => {
        setSaving(true);
        setSaveMessage('');
        setError('');
        try {
          const res = await call(ENDPOINTS.updateConfig, {
            token: token.trim(),
            port: Number(port) || 3088,
            // [refactor 2026-10-21] 单一真源：`remoteAccess`。顶层 npsHost/npsPort/
            // useHttps 由服务端从模型派生，这里再各写一份就会制造两个真源。
            remoteAccess: {
              provider,
              nps: {
                host: npsHost.trim(),
                port: Number(npsPort) || 3088,
                useHttps
              },
              // 非 cloudflared 档也把 token/host 存着：切回去不用重填。
              cloudflared: {
                token: cfToken.trim(),
                host: cfHost.trim()
              }
            }
          });
          setConfig((prev) => ({ ...prev, ...res.config, ...res }));
          setSaveMessage('配置已保存；监听端口变更需重启 dsh web，其余设置立即生效。');
          // 保存后立刻拉一次状态：切到 cloudflared 时隧道正在建立，这一屏要能
          // 马上从"未就绪"走到"已就绪"，而不是等用户自己刷新。
          loadRemoteAccess();
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
        // 只有 provider=nps 时地址才是"用户自己填的公网地址"；cloudflared 的地址
        // 由网关每次建立时生成、且会变，抄一份固定值到手机上必然过期。
        const text = provider === 'nps'
          ? `Host: ${npsHost}\nPort: ${npsPort}\nToken: ${token}`
          : `Host: (由网关下发)\nPort: (由网关下发)\nToken: ${token}`;
        copyText(text, 'fullConfig');
      };

      // [cleanup 2026-10-21] 网关不再托管安装包，原先这里还有 npsApkUrl /
      // localApkUrl 两个指向 /dsh-agent.apk 的变量（已是死代码）。安装包只认
      // GitHub Releases。
      const RELEASES_URL = 'https://github.com/ccleeyx-cyber/dsh-mobile/releases';
      // 手机真正在用的公网地址：nps 档 = 用户填的穿透地址；cloudflared 档只有
      // 网关知道（每次建立都不同），所以优先用实时状态里的值。
      // （npsScheme / publicPort 两个变量随「连接参数」卡改造一起删掉了 ——
      // 地址与端口现在都直接显示 raState 给的完整 URL。）
      const publicHost = provider === 'nps' ? npsHost : (raState?.publicUrl || '');

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

      // [fix 2026-10-21] 复制内容带上 scheme 与可达范围：只有 host:port 的话，
      // 用户不知道是该在外面用还是连同一个 Wi-Fi。
      const qrText = qr
        ? `地址: ${qr.scheme || 'http'}://${qr.host}:${qr.port}\n`
          + `可达: ${qr.reach === 'public' ? '任何网络' : '同一局域网'}\n`
          + `配对码: ${qr.pairCode}\n${qr.ttlMs / 60000 | 0} 分钟内有效`
        : '';
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

          // 远程接入：三选一（严格互斥）
          h('div', { style: S.formGroup },
            h('label', { style: S.label }, '远程接入方式（三选一）'),
            h('div', { style: { display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 8 } },
              ...[
                ['none', '仅局域网'],
                ['nps', '自有反向代理 (NPS)'],
                ['cloudflared', '临时隧道 (cloudflared)']
              ].map(([value, label]) => h('button', {
                key: value,
                type: 'button',
                style: provider === value ? S.primaryBtn : S.btn,
                onClick: () => setProvider(value)
              }, label))
            ),
            h('span', { style: S.helpText },
              provider === 'nps'
                ? '出口是你自己的反向代理：填好外面的域名与端口即可，网关只负责知道自己挂在哪个地址下。'
                : provider === 'cloudflared'
                  ? '免账号，网关自己向外建连；地址每次重连都会变，属于临时通道（需要 TLS 端口可用）。'
                  : '只有同一局域网内的手机能连。')
          ),

          // NPS 只在选中 nps 时才需要填：它是这一档的配置，不是全局配置。
          provider === 'nps'
            ? h('div', { style: { display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 12, marginBottom: 14 } },
              h('div', { style: S.formGroup },
                h('label', { style: S.label }, 'NPS 穿透地址 (Host / Domain)'),
                h('input', {
                  type: 'text',
                  value: npsHost,
                  onChange: (e) => setNpsHost(e.target.value),
                  style: S.input,
                  placeholder: 'n.example.com'
                }),
                h('span', { style: S.helpText }, 'NPS 穿透服务域名或公网 IP。')
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
            )
            : null,

          provider === 'nps'
            ? h('label', { style: { ...S.label, display: 'flex', alignItems: 'center', gap: 8, marginBottom: 14 } },
              h('input', {
                type: 'checkbox',
                checked: useHttps,
                onChange: (e) => setUseHttps(e.target.checked)
              }),
              '穿透采用 HTTPS（强烈建议；明文会让令牌裸露在公网）'
            )
            : null,

          // [feat 2026-10-21] cloudflared 两种形态（参考 dsh-pocket）：
          //   快速隧道 = 不填 token，随机域名、每次重连都会变；
          //   命名隧道 = 填 token + 域名，地址固定。地址稳定才谈得上"能用"。
          provider === 'cloudflared'
            ? h('div', { style: S.formGroup },
              h('label', { style: S.label }, 'Cloudflare Tunnel Token（可选）'),
              h('input', {
                type: cfToken ? 'password' : 'text',
                value: cfToken,
                onChange: (e) => setCfToken(e.target.value),
                style: { ...S.input, fontFamily: 'ui-monospace,SFMono-Regular,Consolas,monospace' },
                placeholder: 'eyJhIjoi…（留空 = 快速隧道）'
              }),
              h('span', { style: S.helpText },
                '在 Cloudflare Zero Trust → Networks → Tunnels 建一条隧道并指向 http://localhost:3088，'
                + '把它的 token 粘到这里即可获得固定域名（重启不变）。留空则用快速隧道。')
            )
            : null,
          provider === 'cloudflared' && cfToken.trim()
            ? h('div', { style: S.formGroup },
              h('label', { style: S.label }, '固定域名 (Host)'),
              h('input', {
                type: 'text',
                value: cfHost,
                onChange: (e) => setCfHost(e.target.value),
                style: S.input,
                placeholder: 'dsh.example.com'
              }),
              h('span', { style: S.helpText },
                '该隧道在 Cloudflare 那边绑定的域名。cloudflared 不会把它打印出来，所以这里必须填。')
            )
            : null,

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

        // 2.5 远程接入实时状态 [feat 2026-10-21]
        h('div', { style: S.card },
          h('div', { style: S.header },
            h('div', { style: S.title }, '🌐 远程接入状态'),
            h('button', {
              type: 'button', style: S.btn, disabled: raBusy, onClick: handleRefreshRa
            }, raBusy ? '刷新中...' : '🔄 刷新')
          ),
          h('div', { style: { ...S.subtitle, marginBottom: 12 } },
            '通道由网关自动建立：申请域名 → 等 Cloudflare 边缘注册 → 就绪。'
          ),
          // [fix 2026-10-21] 阶段进度：一个"未就绪"对用户没有信息量，卡在哪一步
          // 才决定该怎么办（申请阶段失败=出网断了；边缘阶段失败=7844 被阻断）。
          raState && raState.stage && ['preparing','requesting','requested','connecting'].includes(raState.stage)
            ? h('div', { style: { marginBottom: 12 } },
              h('div', {
                style: {
                  height: 4, borderRadius: 2, background: '#e5e7eb', overflow: 'hidden'
                }
              },
                h('div', {
                  style: {
                    height: '100%',
                    width: ({ preparing: '15%', requesting: '35%', requested: '65%', connecting: '85%' })[raState.stage] || '10%',
                    background: '#2563eb',
                    transition: 'width .4s ease'
                  }
                })
              ),
              h('div', { style: { ...S.helpText, marginTop: 6 } },
                `${raState.stageLabel || raState.stage}`
                + (raState.attempts ? ` · 第 ${raState.attempts} 次重试` : '')
                + (raState.elapsedMs ? ` · 已用时 ${Math.round(raState.elapsedMs / 1000)}s` : '')
              )
            )
            : null,
          h('div', { style: S.grid },
            h('div', { style: S.metricCard },
              h('div', { style: S.metricLabel }, '当前方式'),
              h('div', { style: S.metricValue }, providerLabel(raState?.provider || provider)),
            ),
            h('div', { style: S.metricCard },
              h('div', { style: S.metricLabel }, '公网地址'),
              h('div', { style: S.metricValue }, raState?.publicUrl || '（无）'),
            ),
            h('div', { style: S.metricCard },
              h('div', { style: S.metricLabel }, '局域网地址'),
              h('div', { style: S.metricValue }, raState?.localUrl || '（未识别）'),
            ),
            h('div', { style: S.metricCard },
              h('div', { style: S.metricLabel }, '手机现在该走'),
              h('div', {
                style: { ...S.metricValue, color: raState?.ready || raState?.reach === 'lan' ? '#059669' : '#b45309' }
              }, raState?.reach === 'public' ? '公网' : '局域网'),
            ),
          ),
          h('div', { style: { ...S.helpText, marginTop: 8 } },
            '“仅局域网”档下没有公网地址，二维码会编码局域网地址 —— 手机需与电脑同一 Wi-Fi。'
          ),
          raState && raState.reason
            ? h('div', { style: { ...S.helpText, marginTop: 10, color: '#b45309' } }, raState.reason)
            : null,
          raState?.publicUrl
            ? h('div', { style: { marginTop: 10 } },
              h('button', {
                type: 'button',
                style: copiedKey === 'raUrl' ? S.btnSuccess : S.btn,
                onClick: () => copyText(raState.publicUrl, 'raUrl')
              }, copiedKey === 'raUrl' ? '已复制公网地址' : '📋 复制公网地址'))
            : null
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
              h('div', { style: S.metricLabel }, '公网地址'),
              h('div', { style: S.metricValue }, raState?.publicUrl || publicHost || '（无）'),
            ),
            h('div', { style: S.metricCard },
              h('div', { style: S.metricLabel }, '局域网地址'),
              h('div', { style: S.metricValue }, raState?.localUrl || (config?.localIp ? `http://${config.localIp}:${config.port}` : '（未识别）')),
            ),
            h('div', { style: S.metricCard },
              h('div', { style: S.metricLabel }, '授权码 (Token)'),
              h('div', { style: S.metricValue }, token || '未生成'),
            ),
            h('div', { style: S.metricCard },
              h('div', { style: S.metricLabel }, '手机现在该走'),
              h('div', { style: S.metricValue }, raState?.reach === 'public' ? '公网' : '局域网'),
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
              ? h('img', { src: qr.qrDataUrl, alt: '配对二维码', style: { width: 240, height: 240, borderRadius: 8, border: '1px solid var(--dsw-alias-border-l2, #e5e7eb)' } })
              : h('div', { style: { width: 240, height: 240, display: 'flex', alignItems: 'center', justifyContent: 'center', textAlign: 'center', fontSize: 12, color: 'var(--dsw-alias-label-tertiary, #6b7280)', border: '1px dashed var(--dsw-alias-border-l2, #d1d5db)', borderRadius: 8 } }, 'qrcode 包不可用\n请手动输入配对码'),
            h('div', { style: { display: 'flex', flexDirection: 'column', gap: 8, minWidth: 220 } },
              h('div', { style: S.metricCard },
                h('div', { style: S.metricLabel }, '配对码（10 分钟内有效）'),
                h('div', { style: { ...S.metricValue, fontSize: 22, letterSpacing: 4 } }, qr.pairCode)
              ),
              h('div', { style: S.metricCard },
                h('div', { style: S.metricLabel }, '二维码里的地址'),
                h('div', { style: S.metricValue }, `${qr.scheme || 'http'}://${qr.host}:${qr.port}`)
              ),
              h('div', { style: S.metricCard },
                h('div', { style: S.metricLabel }, '扫码的手机需在'),
                h('div', { style: S.metricValue },
                  qr.reach === 'public' ? '任何网络（走公网）' : '同一局域网（同一 Wi-Fi）')
              ),
              // [fix 2026-10-21] 这里的判断以前是 `qr.host !== publicHost` —— 而
              // publicHost 在非 nps 档已不再伪造，提示也就跟着对了：只在"当前
              // 出口是公网、但隧道还没就绪"时提醒一句。
              (qr.reach !== 'public' && raState?.provider === 'cloudflared' && !raState?.ready)
                ? h('div', { style: { ...S.noticeBox, marginTop: 0 } },
                    '隧道还没就绪，二维码里是局域网地址。等它就绪后重新生成，二维码才会带上公网地址。')
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

    // [fix 2026-10-23] 名字必须与包名一致（改名 dsh-mobile-access 后漏改这里 →
    // 客户端插件以旧名注册，宿主按新包名找插件时对不上，"移动终端"面板会静默消失）。
    module.exports = {
      name: 'dsh-mobile-access',
      inject: ['slots', 'connection'],
      apply
    };

    return module.exports;
  }
});
