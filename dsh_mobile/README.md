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

## 二、编译与发布

正式包由 GitHub Actions 构建，不需要在本机安装 Android SDK：

1. 修改 `pubspec.yaml` 的 `version`；
2. 在 `CHANGELOG.md` 写同名版本小节；
3. push 到 `main`，CI 构建分 ABI APK、生成 `latest.json` 并创建 Release。

本机调试只需 Flutter 3.24.5：

```bash
cd dsh_mobile
flutter pub get
flutter analyze --fatal-warnings
flutter test
flutter run $(node ../scripts/app-version.mjs --defines)
```

---

## 三、 使用与配置指南

推荐在电脑端 `设置 → 移动终端` 扫码配对，App 会自动取得设备 Token。

手动接入：

1. 网关默认只监听 `127.0.0.1:3088`；需要手机直连时显式设置
   `BRIDGE_HOST=0.0.0.0`（或 `host: 0.0.0.0`），并确认防火墙放行。
2. 远程优先使用设置页里的 cloudflared / 反向代理；不要把原生 `3080` 暴露到公网。
3. 在 App 填写**地址、端口、Token**；HTTPS 使用 `3443` 并打开开关。
4. 点击「测试连通性」后保存进入聊天。自签证书首次连接会记录指纹，之后指纹变化会被阻止。
