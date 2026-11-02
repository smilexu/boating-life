# P6.2.4 — 钓组视觉与顺序修复

## 实现

- 单钩拟饵改为程序化弯曲金属亮片：约 8.5 cm × 2.4 cm，银色金属主体、蓝绿色点缀、前端线环和三本钩。亮片摆动只改变模型朝向，不改变鱼饵世界位置。
- 鲱鱼串钩改为一条主线、5 个钩位、5 根短支线、羽毛/闪丝装饰、独立小钩和底部胶囊形铅坠。模型节点在实例化时创建，运行时只更新姿态和位置，不创建刚体或逐钩物理。
- 新增串钩顶部与底部子线配置。当前配置为顶部 0.12 m、5 个钩位总跨度 1.8 m、底部 0.14 m；线环到铅坠锚点总长 2.06 m。

## 顺序问题根因与修复

此前 `_bait_world` 实际代表底部铅坠，但鱼线末端也连在这个锚点；钩位则从该点另行向上排布。鱼线端点、串钩主线顶部与钩位没有共用一个拓扑定义，收线约束因此把铅坠当作鱼线挂点。

现在 `_bait_world` 仍是铅坠中心，串钩主线局部 +Y 指向鱼竿侧。鱼线末端连接到主线顶部线环。钩位从铅坠向上按间距计算：Hook 1 最靠近鱼竿，Hook 5 最靠近铅坠。线环、钩位、主线姿态和深度范围都使用同一组世界坐标。姿态由重力向上方向加少量船速/鱼线张力倾斜生成，且始终保持正向上分量，不使用摄像机朝向。

垂直向上收线时，五个钩位按 Hook 1、2、3、4、5 的顺序越过水面，随后铅坠越过水面。当前 Headless 顺序用固定水面和 5 cm 位移步长，根据实际计算出的世界坐标验证；它不是 Forward+ 实际水下画面验收。

HUD 对串钩显示“铅坠深度”，深度来自铅坠世界位置与局部动态水面采样；钩组深度范围来自五个钩位各自的世界位置和水面采样。没有把钩位索引换算成固定深度。相关中英文文案新增 `hud.boat_fishing.line_detail_sabiki_format`。

## 活动范围与按键复核

复查发现第一人称支持判断此前只检查活动区域资源是否非空；若多边形缺失或退化，碰撞边界不会建立，位置约束也可能直接放行。本轮要求活动区域必须具有有效多边形且安全出生点位于有效区域内；无效配置不再允许启动船上活动。现有船体局部边界投影和碰撞行为未改其形状。

放线键沿用现有 F 映射；自动化检查确认 `boat_fishing_pay_out` 绑定 F，R 未绑定该动作。

## 修改文件

- `scripts/boat_fishing_casting_system.gd`
- `scripts/boat_fishing_rig_profile.gd`
- `resources/boat_fishing/sabiki_rig.tres`
- `scripts/boat_hud.gd`
- `resources/translations/fish_species.csv` 及其导入生成的中英文 `.translation`
- `scripts/onboard_activity_controller.gd`
- `tests/test_p6_2_casting.gd`

## 验证

- `godot --headless --editor --path . --quit`：通过。输出包含已有的两组重复 Translation UID 警告，以及退出时一个 ObjectDB 泄漏提示。
- `godot --headless --path . --script res://tests/test_p6_2_casting.gd`：通过。覆盖亮片网格、串钩部件、真实线环连接点、五钩顺序、倾斜不翻转、模拟水面越界顺序、F/R 映射、深度数据和收线后的钩位顺序。Godot 退出时报告一个 DummyShader RID 泄漏。
- `godot --headless --path . --script res://tests/test_p6_1_onboard_activity.gd`：通过。覆盖允许区域、舱口和船舷边界、跳跃、快走、波浪姿态与自动巡航。
- `git diff --check`：通过。
- Forward+：游戏以 Metal 3.2 启动；但自动化界面未提供可检查的游戏窗口，**真实画面检查 NOT RUN**。亮片比例、材质高光和串钩实际水面出水观感仍需人工目视确认。

## 限制

串钩使用轻量的单轴姿态近似，没有逐段绳索模拟；船速和张力只带来有限倾斜。当前水面出水顺序自动检查采用静态平面上的几何越界测试，实际波浪中的画面顺序仍需 Forward+ 验收。
