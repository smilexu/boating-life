# P6.4.6.0 — 单钩与串钩鱼线行为统一报告

## 结果摘要

Single Jig 与 Sabiki 现在共用同一个外部主线状态判断和线形生成流程。Sabiki 原有的专属松线贝塞尔曲线及“收线后保持主线绷紧”的独立标志已删除。搏鱼继续共用 `BoatFishingFightSolver`，手动收放线继续更新唯一的 `_line_paid_out_length_m`。

两种钓组的线端位置仍由各自实际末端结构提供：Single Jig 使用亮片线眼，Sabiki 使用串钩主干顶环。Sabiki 的主干、支线、五个钩位与铅坠仍由钓组视觉及捕获逻辑维护；这些是末端钓组结构，不是第二套主线求解器。

Headless 定向流程通过了 Single Jig、Sabiki、Solver 和鱼竿反馈测试。P6.2 综合测试中有 7 条既有断言失败，均未涉及本次新增的共用主线状态或曲线断言，具体列表见测试结果。没有运行 GPU 画面验收，因此不能据此声称实机折角问题已经彻底消失。

## 修改文件

- `scripts/boat_fishing_casting_system.gd`
- `tests/test_p6_2_casting.gd`
- `tests/test_p6_3_2_sabiki_multi_catch.gd`
- `P6_4_6_0_UNIFIED_FISHING_LINE_REPORT.md`

## 修改前的差异

外部主线虽然一直是同一个 Mesh 和权威线长，但松线视觉分成两套：Sabiki 使用 `_get_slack_sabiki_line_point()`，Single Jig 使用通用下垂曲线。Sabiki 还拥有 `_sabiki_retrieval_taut`，并在手动收线时设置该标志，影响了只有 Sabiki 才有的线条松紧状态。

此外，Sabiki 主干是独立的刚性圆柱，外线终点和主干方向分别计算。主干作为串钩末端模型本身是合理的；连接处的线形规则则不应由钓组类型切换。

## 统一后的数据与几何路径

### 权威线长和主线求解

`_line_paid_out_length_m`（`scripts/boat_fishing_casting_system.gd:148`）仍是唯一的船钓已放线长度。

- WAITING 手动收线/放线以相同速度和限幅更新该字段，见 `scripts/boat_fishing_casting_system.gd:3861-3867`。这一段不按钓组类型分叉。
- 搏鱼时单钩和串钩的 participant 快照共同交给同一个 Solver，Solver 返回的 `line_delta_m` 只提交到该字段，见 `scripts/boat_fishing_casting_system.gd:2589-2622`。
- 最终回收动画根据实际线端距离更新该字段，并在完成时归零，见 `scripts/boat_fishing_casting_system.gd:3973-3987`。

线端的世界位置会因亮片线眼和串钩顶环不同而不同。这是终端几何对实际连接点的描述；收放线规则、Solver、张力处理及线长字段没有按钩数分段。

### 主线松紧状态

`_get_main_line_visual_state()` 是唯一的主线松紧状态判断入口，见 `scripts/boat_fishing_casting_system.gd:4754-4767`。它依据搏鱼 Solver 的松线状态或等待阶段的竿线张力，并统一处理抛投、手动收线、回收和整副钓组出水状态。该函数不读取 `rig_type`。

### 外部主线渲染

`_update_line_and_bait_visuals()` 是唯一的外部主线网格构造入口，见 `scripts/boat_fishing_casting_system.gd:4514-4625`。两种钓组共用：

- 竿尖、导环和末端连接点组成的路径。
- 同一个船体避让路由 `get_hull_clearance_line_route()`。
- 相同的绷紧直线与松线曲线选择。
- 同一个路径切线计算及曲线采样。
- 相同的线半径、网格构造和搏鱼振动反馈。

松线深度由 `calculate_main_line_visual_sag_depth()` 根据跨度长度、松线比例和是否出水计算（`scripts/boat_fishing_casting_system.gd:4653-4665`）。曲线由 `calculate_main_line_visual_curve_point()` 计算（`scripts/boat_fishing_casting_system.gd:4668-4698`）：三次贝塞尔端切线由外线路径方向和实际末端钓组方向提供，并叠加两端归零斜率的 `sin²(πt)` 下垂。Sabiki 与 Single Jig 不会选择不同的曲线算法。

实际连接位置连续：外线终点是 `_get_tackle_line_connection_world()` 返回的钓组线眼，Sabiki 顶环/主干按同一串钩轴布置；可见 Sabiki 主干保持为末端钓组模型，见 `scripts/boat_fishing_casting_system.gd:4725-4751, 4821-4824`。搏鱼时 `_get_terminal_line_connection_offset_world()` 只提供对应的终端几何偏移，再由共同的搏鱼更新路径使用，不会另行改写 Solver 的线长，见 `scripts/boat_fishing_casting_system.gd:2742-2745`。

## 删除的重复机制

- 删除 `SABIKI_SLACK_LINE_MAX_SAG_M`。
- 删除 Sabiki 专属 `_get_slack_sabiki_line_point()` 及其外部主线调用分支。
- 删除 `_sabiki_retrieval_taut` 的声明、写入和重置。
- 将 `_should_render_fishing_line_taut()` 替换为共用的 `_get_main_line_visual_state()`。
- 保留 `_should_keep_sabiki_tackle_aligned()`，但它只决定串钩主干作为末端模型的姿态：水中时沿竿尖到坠子的轴线对齐，整组出水后再向自然垂直姿态过渡。它不计算主线张力、松线程度或权威线长。

代码搜索确认 `scripts/` 和 `tests/` 中不再引用上述已删除的 Sabiki 专属主线曲线、松紧标志或旧状态函数。

## 仍然存在的合理钓组差异

Sabiki 仍然需要独立的末端连接点、五钩位置、支线、主干、铅坠以及逐钩预约/收获处理。抛投后的整组入水检测也会检查多个钩位，避免主干尚未入水就提前进入等待状态。钩组被收至船边时，批量收获路径与单钩收获路径不同。这些分支服务于末端结构与多鱼玩法，不参与外部主线曲线或主线张力求解。

**结论：**两种钓组共用主线物理 Solver、收放线长度状态、主线松紧判定和外部鱼线渲染算法；区别只留在终端连接几何及串钩末端结构/多钩玩法。线端位置和切线必须随钩组实际连接结构变化，因此最终生成的空间曲线不会要求数值上完全相同，但生成规则相同。

## 定向测试

| 检查 | 结果 |
|---|---|
| `test_p6_3_1_single_jig.gd` | 通过，0 failures；包含追饵、中钩、Solver、收线、鱼嘴挂钩、Authority 结算及断线流程 |
| `test_p6_3_2_sabiki_multi_catch.gd` | 通过，0 failures；包含逐钩挂鱼、批量收获和多鱼 Solver 生命周期 |
| `test_p6_4_3_boat_fishing_fight_solver.gd` | 通过，0 failures；单鱼/多鱼拉力、线长边界及帧率时间步检查 |
| `test_p6_4_6_1_rod_drag_feedback.gd` | 通过，0 failures |
| `test_p6_2_casting.gd` | 运行完成；本次新增的共享松紧状态与共享曲线切线断言均通过，但总计 7 条其他断言失败 |
| `git diff --check` | 通过 |

P6.2 综合测试中的 7 条失败断言为：手持线轮视口投影、线轮至竿尖线半径、船流/竿张力下串钩顺序、垂直提起时串钩出水顺序、抛投阶段出线音效请求、按住 F 的放线速度、放线时线轮音效请求。它们涉及本次未修改的线轮投影、既有钩组倾斜/出水顺序及输入音效路径；本次新加的“Single Jig/Sabiki 共享状态”和“共享松线曲线贴合串钩末端轴”检查通过。综合测试不能记为全通过，相关失败也需要后续单独处理。

Headless 测试日志提示 `No rendering device on load`，因此这里只验证代码状态和集成逻辑，没有验证真实 GPU 上线条与串钩主干交界处的最终画面。

## GPU 实机检查步骤

在相同船位与视角下分别使用 Single Jig 和 Sabiki 检查：

1. 水下等待时停止收线，再按住收线并松开。
2. 在水面附近以不同速度收回 Sabiki。
3. 让整副 Sabiki 完全出水并继续回收到竿边。
4. 对照搏鱼时的绷紧线、泄力出线和张力释放。
5. 观察竿尖至 Sabiki 顶环的连接处，以及顶环到刚性主干的切线变化。

Headless 检查无法确认水面遮挡、线材抗锯齿和 GPU 最终几何外观。若交界处仍有折角，下一步应记录折角发生时的 `_get_rod_tip_world()`、`_get_tackle_line_connection_world()`、`_bait_world`、末端切线和 `_get_main_line_visual_state()`，再判断属于线网格连接还是末端圆柱朝向。
