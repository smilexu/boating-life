# P6.4.6.0.2 — Single Jig 与 Sabiki 鱼线统一报告

## 结论

船钓主线现由 Single Jig 与 Sabiki 共用同一套线长状态、等待/搏鱼线长更新、松紧判定和主线网格生成。Sabiki 的钩位主干也沿用同一个线网格，作为末端结构追加在主线之后；五个钩、支线、铅坠及多鱼玩法仍保留。

本次移除了会让 Sabiki 末端朝向影响外线曲线的旧曲线函数，以及“水中沿竿线方向、整组出水后逐渐转向竖直”的姿态切换。测试确认主线不再使用端点切线控制点生成可能反弯的 Bezier 曲线；松线位移只沿重力方向。

## 修改文件

- `scripts/boat_fishing_casting_system.gd`
- `tests/test_p6_2_casting.gd`
- `P6_4_6_0_2_SINGLE_JIG_SABIKI_UNIFICATION.md`

## 调用路径对照

| 阶段 | Single Jig 与 Sabiki 共用的路径 | 保留的钓组结构差异 |
|---|---|---|
| 抛投和入水 | 共用 `_bait_world`、`_bait_velocity_world` 和 `_line_paid_out_length_m`；共同线网格负责显示外线 | Sabiki 等钩组完全入水后再完成首次入水会话记录；这是整副钓组的水面占用判断，不另设主线模拟 |
| WAITING、手动收放线 | `_update_waiting_bait()` 更新共同的 sinker/拟饵位置、线长约束和张力响应（约第 3822 行） | Sabiki 空钩/批次捕获流程不同；不改变主线更新 |
| 松紧判定 | `_get_main_line_visual_state()`（约第 4702 行）不按 rig 类型分支 | 无 |
| 搏鱼 | `_update_fight_controls()` 调用同一个 `BoatFishingFightSolver.solve_step()`，并由 casting system 在同一位置提交 `_line_paid_out_length_m`（约第 2604 行） | participant 与钩位数量不同；不创建 Sabiki 专用求解器 |
| 出水与回收 | `_update_waiting_bait()` 和 `_update_retrieve_animation()` 更新同一个 sinker/拟饵位置；回收长度以实际线连接点计算（约第 3965 行） | Sabiki 以所有钩/连接点判断整组是否完全离水，防止上部出水时把仍在水中的末端误判为整组已离水 |
| 主线与视觉线形 | `_update_line_and_bait_visuals()` 与 `calculate_main_line_visual_span_point()`（约第 4510、4640 行）统一生成外线 | Sabiki 追加顶眼、钩位主干和铅坠的末端点，并保留独立支线与鱼钩 |
| 末端连接 | `_get_tackle_line_connection_world()` 与 `_get_tackle_retrieval_target_world()` 使用同一个偏移来源（约第 4757–4768 行） | Single Jig 的亮片线眼位置与 Sabiki 顶环高度不同，这是实际模型几何差别 |

`_line_paid_out_length_m` 仍是唯一权威线长。绘线函数和钓组模型更新都不写入该值。

## 根因与修复

旧代码存在两种重复的 Sabiki 特例：

1. 松线主线通过 `_get_slack_sabiki_line_point()` 构造 Bezier 曲线，起始控制方向取自主线到连接点的方向，末端控制方向则取自 Sabiki 主干朝下方向。这让外线曲线受主干姿态牵引，控制点在某些端点方向下会使曲线回弯，形成连接处折角或向上拱起。该函数和调用分支已删除。
2. `_get_sabiki_up_direction_world()` 先令串钩轴指向竿尖；整组离水后，再用 `AIRBORNE_RIG_RELAX_DURATION_SECONDS` 把轴旋向自然上方。鱼钩布局随水面状态改变，可能让顶环、主干与外线先后使用不同方向。该强制姿态函数、离水旋转时长常量及相关独立状态已删除。

现在外部各线段统一通过 `calculate_main_line_visual_span_point()` 生成：绷紧时落在两端点的弦线上；松弛时只沿世界重力方向下垂，幅度由共同的松弛比例控制。Sabiki 主干不再控制外线终端切线，也不再按出水状态强制旋转。

Sabiki 布局轴现在由 `_get_sabiki_natural_up_direction_world()` 提供：以重力方向为主，保留现有船速方向造成的小幅倾斜。其用途仅为末端钩位布局，不参与线长、张力、收放线或主线曲线。

## 末端连接与五钩

`_get_tackle_line_connection_offset_world()` 集中定义末端线眼相对 sinker/亮片中心的模型偏移；主线端点与最终回收目标都复用该偏移。因此外线终点、Sabiki 顶眼及回收终点使用同一几何基准。Sabiki 的五个钩根仍按原有 Hook 1–5 顺序布置，支线方向、鱼钩尖端与铅坠结构未改变。实际鱼钩坐标仍来自既有钩位函数，主线渲染不会覆盖或移动其权威坐标。

Sabiki 主干作为共享线网格中的末端几何点序列绘制，不再用独立刚性主干圆柱或独立外线曲线。它没有单独的线长、张力或逐段约束。

## 删除与保留

已删除或停用的旧实现：

- Sabiki 专用松线 Bezier 函数及其外线渲染分支。
- Sabiki 水中强制沿竿线方向对齐的 `_should_keep_sabiki_tackle_aligned()`。
- 整组出水后按时长转向自然竖直的姿态切换及 `AIRBORNE_RIG_RELAX_DURATION_SECONDS`。
- 末端线眼偏移与最终回收目标中重复的 rig 分支计算，改由共同偏移函数提供。

保留的必要差异：

- 单钩只具有亮片末端模型；Sabiki 有五个钩位、支线、顶环和铅坠。
- Sabiki 的入水/完全离水检测查看整组钩位和连接点；这只判定整副钓组是否仍与水面相交，不驱动第二套线形或出水姿态。
- Sabiki 多钩自然中鱼、搏鱼参与者和批量结算流程保持原样。

代码搜索未发现 Sabiki 专属主线 Solver、第二权威线长、独立张力状态或旧 Bezier/姿态切换函数的残留引用。唯一仍按 rig 类型选择的主线相关位置是实际连接点偏移和追加末端钩组结构。

## 定向测试

### P6.2 几何与收线集成脚本

运行：`godot --headless --path . --script res://tests/test_p6_2_casting.gd`

本次新增/相关几何断言均通过：

- Sabiki 主干由共享外线网格绘制，没有第二个 `SabikiMainline` 刚性圆柱。
- 松线曲线的采样点不会高于相同进度的端点弦线；绷紧线沿弦线。
- Sabiki 布局轴不随等待/回收状态、水面状态计时或竿负荷跳变。
- 主线网格连接顶眼、五个钩根和 sinker，覆盖水下、部分出水和离水阶段。
- 线网格更新不改变实际五个钩位或权威放线长度。
- 连续 sinker 位移时连接点随之连续移动；主干方向切换断言通过。

整个 P6.2 集成脚本仍以退出码 1 结束，报 4 个未通过断言：手持卷线器投影位置、手持竿线径与拖钓竿线径对比、按住 F 的连续放线速率、放线音效请求。这四项不是本次修改的主线曲线、Sabiki 姿态或连接几何断言；本报告不把整套 P6.2 写成通过。

### Single Jig 与 Sabiki 闭环回归

- `godot --headless --path . --script res://tests/test_p6_3_1_single_jig.gd`：退出码 0，`failures=0`。单钩追饵、中鱼、搏鱼、收线、结算及断线清理通过。
- `godot --headless --path . --script res://tests/test_p6_3_2_sabiki_multi_catch.gd`：退出码 0，`failures=0`。多钩预约、独立钩位、手动收线、批量结算及取消清理通过；三鱼场景嘴钩误差为 `0.000000 m`。
- Godot 退出时这两个场景均打印 1 个 `RendererDummy MaterialStorage DummyShader` RID 泄漏提示；测试进程仍以退出码 0 完成。
- `git diff --check`：报告写入后执行，退出码 0，无空白错误。

## GPU 验收与限制

测试日志出现 `No rendering device on load.`，本轮只运行 headless 场景，没有完成 GPU 实际画面验收，因此不能宣称截图中的折角/上拱已在画面中彻底消失。

请在 GPU 运行时按此顺序人工检查：

1. Single Jig 水下收线，观察竿尖至亮片线眼的外线。
2. Sabiki 水下收线。
3. Sabiki 上部钩位出水、下部钩位和铅坠仍在水下。
4. Sabiki 整组出水并悬挂，再完成最终回收。
5. 对比相同船速与收线输入下的两种钓组，观察外线端点、顶眼和主干衔接。

当前线形是低成本视觉近似，不是悬链线或弹性绳物理；下垂按世界重力方向与共同松弛比例计算，未积分精确的放线余量。若 GPU 实机仍出现折角，应记录出问题时的端点坐标、末端连接点、钓组轴和外线最后几个采样点，再定位是否来自模型局部坐标或船舷避让路径，而不是恢复 Sabiki 专属曲线补丁。
