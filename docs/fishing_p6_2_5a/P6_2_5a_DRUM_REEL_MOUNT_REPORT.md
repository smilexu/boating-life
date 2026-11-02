# P6.2.5a — 船钓鼓轮安装修复

## 修改内容

- 船钓继续调用 `FishingRodRig.create_reel_assembly()`，复用拖钓所用的鼓轮、旋转卷筒、摇柄和绕线圈；没有建立第二套卷线器。
- 新增鱼竿局部 `ReelMount`。其 Z 轴沿竿身，X 轴映射到当前第一人称画面的左侧，使鼓轮主体落在鱼竿左边。手持版安装座收窄并沿竿身布置；拖钓固定安装座没有改动。
- 鼓轮保持工厂原有 `ReelSpinningAssembly` 结构：初始 Z 旋转 90°，其局部旋转轴为 Y，换算到鼓轮装配根节点为 -X。船钓沿用 `FishingRodRig.REEL_ROTATION_SIGN`。收线速度根据实际线长变化率计算为 `-d(line_length)/dt × 5 rad/s`，因此收线与放线会沿相反方向驱动同一卷筒。
- 鼓轮上保留 10 圈低成本绕线视觉。线长减少时绕线圈逐步显现，放线时逐步隐藏；线长是权威数据，动画不反向驱动鱼线。
- 船钓手持竿现有鱼线从鼓轮出线点经过 6 个随竿身弯曲更新的导环到竿尖，再连接到水中的钓组。路径段数按完整路径生成，避免旧的固定 8 段绘制只覆盖到导环中途。

## 实际画面检查

在 Apple M2 Pro 的 Godot Forward+ 中启动 `main.tscn`，从活动菜单开启船钓并让相机朝船尾水面。检查了 READY、真实最短抛投后的 WAITING，以及手动收线画面：鼓轮位于画面中的鱼竿左侧，卷筒绕线可见；WAITING 线段从鼓轮经导环连到竿尖及水面钓组；手动收线过程中卷筒和摇柄姿态发生旋转。三张 Forward+ 截图：

- [READY](boat_fishing_reel_ready_forward_plus.png)
- [WAITING](boat_fishing_reel_waiting_forward_plus.png)
- [手动收线](boat_fishing_reel_reeling_forward_plus.png)

## 测试结果

- `godot --headless --path . --script res://tests/test_p6_2_casting.gd`：通过。覆盖安装父节点、卷筒归属旋转组件、屏幕投影在竿身左侧、鼓轮绕线、线段完整绘制、收线和自动回收旋转，以及拖钓视角/显示回归。
- `godot --headless --path . --script res://tests/test_p6_2_5_reel_audio.gd`：通过。确认鼓轮收线与放线沿同一局部轴反向旋转，原有音效事件接口仍通过。
- `godot --headless --path . --script res://tests/test_fishing_p3_1.gd`：通过，拖钓卷线器轴和收线方向回归检查通过。
- `godot --headless --path . --editor --quit`：导入完成。编辑器输出两条已有的 docs/sailing 极坐标报告翻译资源 UID 重复警告，与本次改动无关。
- Forward+ 中使用 `request_cast()` 完成真实最短抛投进入 WAITING，并进行了手动收线视觉截图检查。没有进行实际玩家长时间操作或独立听音验收；本轮没有修改音效触发逻辑。

## 限制

鼓轮外观仍由轻量程序化几何构成，没有外部高精模型或真实排线机构。Forward+ 临时主场景退出时 Godot 报告了渲染 RID 清理警告；截图画面和状态运行完成，自动化测试未报告功能断言失败。
