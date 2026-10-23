# 手机远程访问（DSH Mobile Bridge）

在手机上继续用你的 DeepSeek Harness：带**设备鉴权**的移动网关，装好即监听 `3088`，手机扫码配对后即可看会话、发消息、批审批、取交付物、跑 Runbook。宿主机原生的 `3080` 端口**不需要**暴露到公网。

## 它解决什么

- **不暴露 3080**：3080 能执行 shell、读写本地文件，直接映射公网等于把机器交出去。本插件在 `3088` 上做一层带 Token 的设备鉴权，未配对设备一律 `401`。
- **手机能干活**：会话切换与流式回复、审批（含通知栏批准）、交付物预览/下载、轨迹与用量、Runbook 一键排障、告警收件箱、工作区/会话管理。
- **按设备撤销**：每台配对手机是独立设备记录，电脑端移除后该设备立刻失联（其它手机不受影响）。

## 安装

插件市场里点「一键安装」，或命令行：

```bash
dsh plugin --profile web add dsh-mobile-access
```

安装后重启 dsh web（插件在进程内，不热重载）：

```bash
# Linux（systemd）
sudo systemctl restart dsh-web
# Windows：双击 %USERPROFILE%\.dsh\profiles\web\restart-dsh-web.cmd
```

## 首次使用

1. 电脑端打开 `设置 → 移动终端`，页面上会显示配对二维码与网关地址。
2. 手机装同款客户端（Android，见仓库 Releases），扫码配对。
3. 手机自动拿到设备 Token，之后无需再配。

手动接入时填三样：**电脑地址**（局域网 IP 或域名）、**网关端口**（默认 `3088`）、**Token**（电脑端设置页可见）。多台电脑可以在 App 里各存一条，用别名区分。

## 端口与网络

| 端口 | 用途 | 是否需要对公网暴露 |
|---|---|---|
| 3080 | DSH 原生 Web（能执行命令） | **不要**暴露 |
| 3088 | 本插件的移动网关（Token 鉴权） | 需要手机能到达时只暴露它 |
| 3443 | 可选 HTTPS/WSS（自签证书，手机首次连接时信任指纹） | 同上，推荐用它而不是明文 3088 |

远程访问可以在「设置 → 移动终端 → 远程接入」里选 `cloudflared`（自动建立隧道，无需公网 IP）或 `nps`（自建反向代理）。

## 配置

全部配置在 `~/.dsh/mobile-bridge/config.json`，由设置页管理，一般不需要手改。可用环境变量覆盖：

| 变量 | 作用 | 默认 |
|---|---|---|
| `DSH_AUTH_TOKEN` | 覆盖共享 Token（未设置则首次启动随机生成） | 自动生成 |
| `BRIDGE_TLS_PORT` | HTTPS/WSS 端口 | `3443`（`0` = 关闭） |
| `DSH_HOME` | DSH 数据目录 | `~/.dsh` |
| `BRIDGE_TRUST_PROXY` | 信任反向代理传来的 `X-Forwarded-*` | 关 |

`cordis.patch.yml` 里也可以直接给实例配置 `port` / `dshPort`。

## 能力边界（安全设计）

- **不开 shell**：快捷命令与 Runbook 走固定 argv 白名单执行器，`|`、`&&`、重定向一律拒绝；高危条目必须二次确认。
- **只读角色**：配对的设备可申请 `readonly`，写动作（发消息、改策略）被网关拒。
- **命令与文件都有上限**：输出截尾、目录列表有上限、文件读取有大小上限。
- **密钥轮换自愈**：引擎轮换 `~/.dsh/.credentials.yaml` 后，网关会重读密钥并重试一次，不需要重启。

## 目录结构

```
dsh-server-plugin/
├── package.json          # 插件元数据 + dsh.bundle 声明
├── cordis.patch.yml      # Bundle Patch：把插件挂进 profile
├── lib/                  # 网关实现（纯 JS，无构建步骤）
├── client/               # 设置页内的前端面板
├── public/               # 独立管理页面
└── LICENSE
```

## 卸载

```bash
dsh plugin --profile web remove dsh-mobile-access
```

卸载不会删除 `~/.dsh/mobile-bridge/`（设备与配置记录）；需要彻底清理时手动删除该目录。

## 兼容性

- Node.js **≥ 22.15**（会话标题解码用到内置 zstd）。
- DSH 客户端（桌面/Web）需支持 `dsh.bundle.patch` 的插件挂载。

