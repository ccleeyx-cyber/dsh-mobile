# DSH Mobile - Flutter 安卓手机端客户端

专为 **DeepSeek Harness (DSH)** 打造的现代移动端智能体控制应用。支持公网远程连接、深度思考（Thinking）折叠查看、Agent 工具调用过程展示与 Markdown 流式渲染。

---

## 一、 功能亮点

- 🛡️ **安全隔离与鉴权**：配合 `dsh-server-plugin` 专用网关，公网连接必须验证 Token，防止恶意探测与未授权操控。
- 💭 **思维链 (Thinking) 可视化**：自动识别模型推理过程，可折叠/展开，保持界面整洁。
- 🛠️ **Agent 工具执行状态**：实时展示 Agent 调用的终端命令（如 Shell、文件读写等）及其输出。
- ⚡ **长连接心跳保活**：支持网络切换（Wi-Fi/移动流量）与息屏后断线自动重连。
- 📝 **完整 Markdown 渲染**：代码块独立高亮、支持表格与长文本复制。

---

## 二、 编译打包 APK 步骤

### 1. 环境准备
确保电脑已安装：
- [Flutter SDK](https://docs.flutter.cn/get-started/install) (推荐 3.19+)
- Android Studio / Android SDK (带 Command-line Tools)

### 2. 获取依赖并构建 Release 安装包
在 `dsh_mobile` 目录下打开终端执行：

```bash
# 1. 下载依赖
flutter pub get

# 2. 构建独立 APK 安装包 (arm64 或 通用包)
flutter build apk --release
```

编译完成后，APK 文件位于：
`build/app/outputs/flutter-apk/app-release.apk`

将该 `.apk` 文件通过微信/QQ/数据线传输到安卓手机上直接安装即可！

---

## 三、 使用与配置指南

1. **在服务器启动 DSH 及网关**：
   参考上级目录 `dsh-server-plugin` 中的说明，在 DSH 宿主机上运行 `node index.js`（默认监听 3088 端口）。
2. **在路由器配置端口映射**：
   将外网 TCP 端口 `3088` 映射到宿主机内网 IP 的 `3088` 端口。
3. **在手机 App 中输入**：
   - **公网 IP**：你的公网 IP 或动态域名
   - **端口**：`3088`
   - **Token**：与服务端环境变量 `DSH_AUTH_TOKEN` 一致的密钥
4. 点击 **“测试连通性”**，显示通过后点击 **“保存并进入聊天”** 即可开始与 DSH Agent 对话！
