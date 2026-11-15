# Direction Approved · dsh_mobile 样式改版

- 展示：2026-11-15 三方向板（design-demos/shot-a-cockpit.png / shot-b-swiss.png / shot-c-materialyou.png），每板含对话 + 工作区两主屏。
- 用户选择原话（ask_user_question 回传）：「A · 驾驶舱（深色仪表）」
- 落地范围：token 色板换驾驶舱取值（深/浅两侧）＋ 签名件改型：底部导航（等宽大写 + 顶发丝指示线）、状态读数条（五格仪表）、工具卡（$ 前缀终端头）、用户气泡（12 圆角＋右下 3px 切角）、composer（内嵌暗面板 + 等宽占位 + 绿色方发送）、工作区行（等宽 meta +  monospace 芯片）。
- 构建：不本机构建，commit → push → GitHub Actions 出包（用户长期规约）。
