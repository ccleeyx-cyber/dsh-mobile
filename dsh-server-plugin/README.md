# DSH Mobile Bridge & 安全认证网关

本项目用于连接 **DeepSeek Harness (DSH)** 与移动端（Android Flutter App），提供专用的移动端流式传输与**公网安全鉴权保护**。

---

## 为什么需要这个网关？

1. **安全隔离（最核心）**：
   DSH 原生 Web 端（默认 3080 端口）具有操作宿主机终端（Shell 执行、本地文件读写）的高级权限。如果直接将 3080 映射到公网且缺乏严格鉴权，极易遭受扫描器爆破攻击。
   通过本网关（默认 3088 端口），所有未经携带 Token 的请求会被直接拦截拒绝（401 Unauthorized）。
2. **移动端协议适配**：
   提供 `/health` 健康检查接口，支持心跳保活与 WebSocket 状态透明代理。

---

## 部署运行方式

### 方式一：独立服务运行（最简单，无需改动 DSH 源码）

确保服务器上安装了 Node.js（v18+）：

```bash
cd dsh-server-plugin
npm install

# 启动网关（可指定 Token 密码和监听端口）
# Linux / macOS:
DSH_AUTH_TOKEN="YourCustomSecretKey123" BRIDGE_PORT=3088 node index.js

# Windows PowerShell:
$env:DSH_AUTH_TOKEN="YourCustomSecretKey123"
$env:BRIDGE_PORT=3088
node index.js
```

> **提示**：建议使用 PM2 进行后台常驻运行：
> `pm2 start index.js --name dsh-mobile-bridge`

### 方式二：作为 Cordis 插件加载

在 DSH 的配置文件（如 `cordis.yml`）中挂载插件：

```yaml
plugins:
  # 其他已有插件...
  dsh-mobile-bridge:
    token: "YourCustomSecretKey123"
    port: 3088
```

---

## 路由器 / 云服务器端口映射设置

- **内网 IP**：你的 DSH 运行电脑的内网 IP（如 `192.168.1.100`）
- **内网端口**：`3088`（**注意：映射 3088 网关端口，切勿再暴露 3080**）
- **外网端口**：`3088`（或自定义任意外部端口）
- **协议**：TCP
