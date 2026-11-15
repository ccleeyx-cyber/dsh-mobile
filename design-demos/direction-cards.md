# 方向卡 · dsh_mobile 安卓端样式改版（2026-11-15）

任务：现有 Flutter 应用（Material 3 + token 色板 #3F5AF0 / #F1F5F9 / 白卡）整体视觉升级。
六候选 → 三方向。缩略对比见 shot-*.png。

## 最佳设计师思路
1. **驾驶舱 Cockpit**（入选 A）—— 把 agent 会话当飞行任务：深色石墨、发丝线、等宽读数仪表条。思维来源：Linear / Raycast 暗色 + tmux 状态行。
2. 阅读模式编辑排印（淘汰）—— AI 正文在本 app 已是裸排，再叠大字号编辑层会牺牲工具类应用的信息密度；与 B 的网格家族外观过近。

## 现实参照（同媒介：移动 IM / agent 客户端）
3. **Material You 原生通讯**（入选 C）—— Google Messages / Telegram 骨架：tonal 面、胶囊气泡、悬浮 composer。参照核实：本机 Chrome 打开 messages 风格规范与 Telegram 界面截图对照过结构。
4. Telegram 桌面 dense 列表（淘汰）—— 与现状差异太小，不构成"方向"。

## 秒数轮盘（风格库随机）
5. **瑞士网格 Swiss Grid**（入选 B）—— 抽中 International Typographic Style：墨线网格、字重层级、单红信号。
6. 暖纸手册风（淘汰）—— 暖奶油+衬线是 AI 默认外观家族，与代码工具题材无关，直接否。

## 三方向差异自检
- 外观家族：暗色仪表 / 纯白硬边 / tonal 圆角，三家不撞。
- 圆角语言：A 8-12 / B 0 / C 16-28。
- 信号色：绿 / 红 / 蓝紫容器。
- 用力过头检查：无整页道具化隐喻；B 的墨线是风格本体不是装饰。
