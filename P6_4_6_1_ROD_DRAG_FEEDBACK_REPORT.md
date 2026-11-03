# P6.4.6.1 船钓泄力交互与负荷反馈报告

## 结论

本轮修正了船钓竿弯视觉标定偏弱的问题，增加鱼的 Burst、张力释放、鱼线受力和泄力调节反馈。没有改动鱼力、泄力物理、线长、Solver 或断线规则。

GPU 实机画面尚未验收。本轮自动测试均使用 headless，日志显示 No rendering device on load，因此结果只验证脚本数据链和数值行为，不能证明实际画面弧度、振动或材质观感已达到目标。

## 原因与数据链

原有竿弯使用 tension_ratio（张力 / 68 N 断线强度）乘 10°。因此 2.2 N 鲱鱼拉力约为 0.32°，1.78 m 竿长上的竿尖偏移约 5 mm；12 N 拉力约为 1.76°。这是玩家几乎看不出竿弯的直接原因。现有 Shader 本身已经能沿竿长形成弧线，主要问题是输入角度过小。

船钓搏鱼步骤仍先更新 participant，再调用同一 Solver；Solver 的 tension_n、line_delta_m 和线速由船钓系统读取；权威线长仍只在同一搏鱼更新位置提交一次。Q/R 改变现有 _fight_drag_setting 并传给下一步 Solver。菜单、鼠标悬停 UI 或 GUI 焦点时不会修改泄力。

关键位置：
- scripts/boat_fishing_casting_system.gd：drag 输入和限幅约 2148–2185 行；Solver 输入及权威线长提交约 2189–2228 行；张力到竿弯和动态反馈约 2229–2288 行。
- scripts/boat_fishing_fight_solver.gd：Solver 未修改。
- project.godot：现有 Q/R 映射约 48–57 行，未新增或重绑按键。
- scripts/fishing_rod_system.gd：拖钓 presentation 本轮未修改。

## 实施内容

### 鱼竿弯曲和动态反馈

新增可在 Inspector 调整的纯视觉参数，见 scripts/boat_fishing_casting_system.gd 约 92–104 行：

| 参数 | 初始值 | 用途 |
|---|---:|---|
| 视觉参考负荷 | 18 N | 弯曲视觉标定，不是泄力或断线阈值 |
| 响应指数 | 0.6 | 中等张力较早产生可见弧度 |
| 持续弯曲上限 | 34° | 竿身主要弧度 |
| Burst 冲击 | 11° | Burst 开始时的短促下压 |
| Burst 衰减 | 0.28 s | 冲击回落时间 |
| 释放回弹 | 最多 3.5° | 张力降低后的短暂反向过冲 |
| 普通微振幅 | 0.9° | 持续受力时竿尖振动 |
| Burst 微振幅 | 2° | 冲刺中的额外振动 |
| 竿尖振动频率 | 7.5 Hz | 确定性正弦组合 |

持续弯曲公式：

base_bend_deg = 34° × clamp(tension_n / 18 N, 0, 1)^0.6

新增的纯逻辑测试给出：2.2 N → 9.63°；10 N → 23.90°；30 N → 34°。竿弯使用 Solver 的真实 tension_n，不再用断线比例作为唯一标尺。Burst、微振和回弹只改变 Shader 输入角度，不回写张力。组合后的正向角度限制在 rad_to_deg(0.8)，约 45.84°。

各鱼按 catch ID 取得稳定相位，多个参与者的振动错开。张力上升采用约 0.07 s 的视觉平滑，下降约 0.15 s。Burst 开始增加 11° 短脉冲；持续微振约 0.9°，Burst 期间另加约 2°。张力显著下降后加入最多 3.5°、约 0.32 s 衰减的回弹。鱼获提起和断线后也播放阻尼恢复。

Shader 以竿长位置生成分布式弧线；本轮让弯曲方向尽量朝向鱼线，并让竿尖和导环使用同一条弯曲中心线。握把不作为刚体旋转。竿弯仍然只用于显示，Solver 始终使用直竿尖。Shader 在 shaders/boat_fishing_rod_bend.gdshader:4；方向、竿尖和导环联动见 casting system 约 3181、4051–4068、4625–4674 行。

### 鱼线和线轮反馈

- 鱼线视觉松弛比例为 1 - clamp(tension_n / 8 N, 0, 1)^0.7。0 N 保留原松弛，8 N 视觉拉直；2.2 N 时松弛比例约 0.594。搏鱼时，按住左键或 Sabiki 残留的检索标记不再强制画成绷紧直线，末端松弛由 Solver 实际张力决定。它只改变显示曲线，不移动鱼钩或鱼，也不修改权威线长。
- 受力鱼线只在船体外的末端线段加最多 1.2 cm、8.5 Hz 的确定性微振；振幅随真实张力或 Solver 实际出线速度增加，两端衰减到零。原有甲板避线和深度遮挡保留。
- 船钓显示线半径从共享拖钓默认值 1.2 mm 调到 1.5 mm（直径 2.4 mm → 3.0 mm），材质仍为浅色、非发光且保留深度测试；没有改拖钓线。
- 线轮动画和循环音效依据 Solver 实际 line_delta_m / line_rate_mps：实际向外运动选择泄力出线，实际向内运动选择收线，线不动则停播。即使玩家按住左键，若鱼实际拉出线仍以 Solver 结果为准。音效桥见 casting system 约 3754–3800 行，本轮没有新增音效资源。

### 泄力操作、HUD 与 F3

沿用 Q 降低、R 提高，连续调整速度为现有 fight_drag_adjustment_per_second（默认 0.35 / 秒）；完整 0–1 行程约 2.86 秒。收线时可以同时调节。按键松开即停止，值限制在 [0,1]；输入使用真实经过时间，立即传给下一步 Solver。

HUD 保留原有搏鱼行内 DRAG 百分比，并新增约 1.25 现实秒的醒目方向提示，如 DRAG ↑ 48% / DRAG ↓ 13%。普通 HUD 不显示张力 N、鱼体力或断线危险值。中英文文案在 resources/translations/fish_species.csv:449，编译翻译资源由 Godot 导入生成。

F3 增加竿弯目标/实际角度、竿尖振幅、Burst 冲击和鱼线视觉张紧比例。物理张力、泄力阈值和线速仍显示在既有调试行。快照接口见 casting system 约 1102–1168 行；面板见 scripts/fishing_debug_panel.gd:1041。

### Sabiki 几何隔离

回归测试发现，如果搏鱼中的 Sabiki 主线方向引用弯曲后的视觉竿尖，三条鱼的鱼嘴—钩尖误差会短暂达到 1.48 cm。现搏鱼和提鱼时 Sabiki 几何继续参考 Solver 的直竿尖；Shader 弯曲只影响竿、导环和鱼线表现，不再反馈到钩位。修复后复测三鱼鱼嘴—钩尖最大误差为 0.000000 m。代码位置在 casting system 约 4288 行。

## 修改文件

- scripts/boat_fishing_casting_system.gd：纯视觉弯曲、振动、方向、线形、提鱼/断线回弹及泄力反馈字段；权威线长仍只在原搏鱼更新处提交。
- scripts/boat_hud.gd：泄力方向提示。
- scripts/fishing_debug_panel.gd：F3 只读视觉数据。
- shaders/boat_fishing_rod_bend.gdshader：方向可控的弧形顶点变形。
- resources/translations/fish_species.csv 及英文、简体中文 .translation 导入产物：文案。
- tests/test_p6_4_6_1_rod_drag_feedback.gd：本阶段纯逻辑测试。
- tests/test_p6_3_1_single_jig.gd：增加整合断言，检查鲱鱼弯曲目标和线张紧诊断。

本轮没有修改鱼种力量/体力、线轮 Profile、Solver、承载力、自然中鱼概率、Authority 或拖钓实现。

## 定向测试

Godot 4.7.2 运行结果：

| 测试 | 结果 |
|---|---|
| tests/test_p6_4_6_1_rod_drag_feedback.gd | 通过，0 failures；2.2 N / 10 N / 30 N 弯曲目标为 9.63° / 23.90° / 34°；泄力限幅、线松紧、方向及收放线音效状态通过 |
| tests/test_p6_4_3_boat_fishing_fight_solver.gd | 通过，0 failures；Solver 回归 |
| tests/test_p6_4_5_boat_fishing_visual_motion.gd | 通过，0 failures；固定线长侧移、鱼嘴锚定及 30/60 FPS 行为通过 |
| tests/test_p6_3_1_single_jig.gd | 通过，0 failures；中鱼、Q/R、竿弯目标、收线、断线、Authority 结算通过 |
| tests/test_p6_3_2_sabiki_multi_catch.gd | 通过，0 failures；多钩、鱼嘴绑定、搏鱼、批量结算通过；三鱼嘴钩最大误差 0 m |
| tests/test_p6_4_5_2_ambient_fishing.gd | 通过，0 failures；普通海域完整船钓流程回归 |
| tests/test_fishing_p3.gd | 通过，0 failures；拖钓原有自动搏鱼与结算回归 |
| git diff --check | 通过，无空白错误 |

headless Godot 退出时出现 DummyShader RID 清理提示，但各测试脚本均报告 failures=0。它不能证明 Shader 已经过 GPU 编译或实际画面验证。

## GPU 验收和限制

本轮没有在 GPU 画面确认竿弧、鱼线振动、逆光可见性或 HUD 排版，也没有生成对照截图。当前自动化运行均为 headless，日志显示无 RenderingDevice，因此 Shader GPU 编译、材质在明暗水面上的实际观感以及按键组合的实机手感仍待桌面验收。

建议人工步骤：运行主场景并进入船钓第一人称；打开 F3 → Fishing，Single Jig 下生成 Sea Trout 测试鱼；短按或持续按住 Q/R，检查 DRAG ↑/↓、竿弧与线轮实际方向；比较低、中、高泄力；之后选择 Sabiki 填入多条测试鱼，检查竿弯随合成张力变化、鱼线不穿甲板、每条鱼嘴保持连接各自钩尖。

视觉参考负荷、振动幅度、线振和竿尖恢复速度是初始美术标定值，尚未经过 GPU 实机手感调校。当前用轻量弧线和确定性正弦振动表现鱼线反馈，不模拟真实竿身材料或绳索弹性。
