# P6.2.5b 鼓轮视觉与鱼线路径验收

## 实现

- [fishing_rod_rig.gd](../../scripts/fishing_rod_rig.gd) 为拖钓和船钓共用同一套鼓轮生成器。鼓轮固定框架、窄座、支撑、薄侧盖（半径 0.043 m、厚 0.006 m）、线轴、摇柄和旋转方向都由这套组件提供。线轴半径 0.028 m、宽 0.064 m；侧盖不随收线旋转。
- [boat_fishing_casting_system.gd](../../scripts/boat_fishing_casting_system.gd) 将 ReelMount 放在竿根沿鱼竿局部轴 0.35 m 处，并沿视觉左侧偏移 0.02 m；共享装配内部的线轴中心再沿竿轴前移 0.19 m，最终鼓轮中心距竿根约 0.54 m，约为竿长（1.78 m）的 30%。上一轮 0.41 m 的位置改动幅度不够，本轮又向握柄侧移动 0.06 m。实际 Forward+ 第一人称投影中心约为视口 `(71.2%, 79.3%)`，位于用户红框覆盖区域内；位置是在鱼竿局部坐标中调整，没有移动鱼竿或相机。
- 旋转组件局部 Y 轴是鼓轮轴；安装时将它转换为鼓轮横轴，保持与拖钓相同的 `REEL_ROTATION_SIGN = -1`。船钓根据实际线长变化率和当前有效半径计算转速，鼓轮只显示权威线长的变化，不反向改动线长。摇柄随旋转组件转动。
- 线轴使用固定 MultiMesh 绕线层：56 圈预生成 Torus，沿轴宽排列；每个圆环使用低面数网格。Torus 的 X/Z 半径按线长缩放，轴向宽度和圈间距不变。绕线半径使用核心半径 0.028 m 加视觉厚度，厚度由 0.012 m（线长 0 m）线性降至 0.003 m（线长 50 m）；超过 50 m 保持最小可见厚度。该显示映射不表示真实线容量，也不影响鱼线或钓鱼模拟。
- 鱼线按“绕线外缘切点 → 固定导线器 → 六个竿环 → 竿尖 → 实际钓组”构造。首个手持竿环位于竿长 50% 处，后续延伸至 97%。船钓沿用拖钓的 0.0012 m 线半径，绕线外缘切点会随视觉厚度更新。单钩和串钩共用这条线路。

原先出线起点使用线轴中部附近的固定点，缺少明确的外层切点和导线器段。手持竿还使用了比拖钓粗近三倍的线径，首导环也过于靠近鼓轮，近景看起来像白色折线。本轮改为动态外缘切点、固定导线器、顺序导环路径，并统一细线半径；Forward+ 图中线路连续通过竿环，没有重复或游离的卷线器附近弯线。

## Forward+ 画面

以下截图来自实际主场景的 Godot Forward+ 运行；测试脚本进入船钓、执行抛投，并在等待阶段主动放线，再持续收线。viewport 为 1300×890。READY、WAITING 和 REELING 均使用本次调整后的安装位置。

| 状态 | 截图 |
|---|---|
| READY | [查看截图](boat_fishing_reel_ready_forward_plus.png) |
| WAITING（放线约 27.2 m） | [查看截图](boat_fishing_reel_waiting_forward_plus.png) |
| REELING（收至约 16.7 m） | [查看截图](boat_fishing_reel_reeling_forward_plus.png) |

READY 中绕线层清晰可见；WAITING 到 REELING 期间实际线长减少约 9.4 m，绕线层同步变厚，线轴和摇柄随真实线长变化旋转。屏幕中鱼竿在右、鼓轮靠近竿根并位于其左侧。较小的线长变化会产生较细微的厚度变化，这是 50 m 视觉量程下的预期效果。

本次 READY 截图中，鼓轮已沿竿身向手持端下移，中心落在用户标记区域内。鱼竿握柄、竿身和整体持竿姿态未移动；调整的是 ReelMount 沿竿轴偏移和轻微的屏幕左侧偏移。

## 测试

- `Godot --path . --script tests/test_p6_2_5_reel_audio.gd`（Forward+）：通过，0 failures；覆盖共用鼓轮结构、线轴轴向、径向厚度更新、外缘出线点、旋转方向及现有音效事件接口。
- `Godot --headless --path . --script tests/test_p6_2_casting.gd`：通过；抛投、线长、导环线路、收放线、声音请求和拖钓视角回归均通过。Headless 退出时报告一个 DummyShader RID 泄漏。
- `Godot --headless --path . --script tests/test_fishing_p3_1.gd`：通过，0 failures；拖钓鼓轮轴、方向和 P3 表现回归通过。
- 按用户红框位置进一步下移 ReelMount 后，重新运行 `godot --headless --path . --script tests/test_p6_2_casting.gd`：通过；检查确认安装点沿竿轴靠近握柄，鼓轮仍在相机视口内并位于鱼竿屏幕左侧。红框位置由 Forward+ 截图检查。
- `Godot --headless --path . --editor --quit`：导入和脚本扫描完成。输出仓库现有两组 duplicate translation UID 警告，以及退出时一个 ObjectDB 泄漏警告。
- `git diff --check`：本次位置修正后通过。

Forward+ 截图运行结束时 Godot 报告 Particle/RenderingDevice RID 和资源泄漏；截图与运行状态已成功生成。该退出告警未在本轮修改中处理。没有进行耳机听感验收；既有收放线音效逻辑与资源未在本轮重做。
