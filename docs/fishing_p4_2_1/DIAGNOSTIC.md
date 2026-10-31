# Fishing P4.2.1 — 可见鱼群与声呐回波定向诊断

## 结论

主要原因已由实际场景扫描数据确认：玩家看到的是 `FishSchoolRenderer` 按学校 ID 生成的个体鱼，它们会在 Authority 学校锚点周围游动；P4.1 声呐则把 Authority 学校锚点及其当前活动深度当作单个聚合目标。浅水目标的 10° 半锥水平覆盖半径只有厘米到几十厘米。玩家即使把换能器开到视觉鱼的位置，学校锚点也可能离开这个窄锥，因此本次扫描不会产生回波，后续扫描历史与 P4.2 画面自然也没有变化。

这次三种现实场景鱼群的对照都只因 `outside_beam` 被排除，没有因底部无效、深度上限、斜距、有效性或声呐 UI 绘制而丢失。

## 视觉鱼与 Authority 的关系

- `FishResourceManager` 的 Authority 是鱼类生态数据源；`FishSchoolRenderer._update_visible_fish()` 从 `get_schools_near()` 取得学校。
- Renderer 个体 ID 以 `"<school_id>:<index>"` 构成，鱼个体视觉状态保存在同一学校 ID 前缀下；没有独立于学校的鱼群种群由这个 MultiMesh 鱼群渲染器创建。
- 实际 MultiMesh 鱼的位置由 Authority 锚点加鱼个体的本地游动 offset 生成。针鱼、海鳟和鲱鱼的基础 `school_wander_radius_m` 是 5.2 m。受惊散开时，视觉活动半径还可增加 `surface_fish_scatter_extension_m × scatter_radius_extension_factor`，项目默认最大约 4.25 m；这是客户端视觉状态，不会改写 Authority 的共享学校锚点。
- Renderer 对表层周期学校还会做只读视觉锚点平滑/预测（`AUTHORITY_SCHOOL_DRIFT_SCALE = 0.16`），所以瞬时绘制位置也不保证与传感器采样位置完全重合。
- 海豚等其他水生视觉由独立系统管理，不属于 Authority 鱼学校，也不会成为鱼群回波。F3 现在会说明无法把声呐候选之外的其他模型匹配到学校。

## 实测几何

自动化集成测试加载真实 `main.tscn`、1510 个本地 Authority 学校和实际 Renderer。测试先通过现有 F3 观察入口选择可见学校，然后将测试探头 XZ 放在最近的已生成 MultiMesh 鱼实例处，执行真实 `FishFinderSensor.scan(true)`。记录中的“视觉偏移”是该鱼实例相对 Authority 锚点的水平距离；“目标深度”与“声束半径”取自这次传感器扫描。

| 鱼种 | School ID | 最近实例距锚点 / 探头距锚点 | 目标深度（探头基准） | 10° 半锥半径 | 结果 |
|---|---|---:|---:|---:|---|
| 针鱼 | `needlefish_v5_18_-12` | 4.44 m | 0.41 m | 0.07 m | `outside_beam` |
| 鲱鱼 | `herring_v5_17_-14` | 2.39 m | 1.82 m | 0.32 m | `outside_beam` |
| 海鳟 | `sea_trout_v5_15_-17` | 2.72 m | 1.50 m | 0.27 m | `outside_beam` |

半径符合当前锥形计算 `r = depth × tan(10°)`。例如针鱼实例即使位于探头 XZ 处，传感器所代表的学校锚点仍相差 4.44 m，而该深度声束半径约 0.07 m。三个实测偏移都明显大于对应覆盖半径。

## 数据链定位

`Authority School → FishFinderSensor.scan() → bounded scan history → FishFinderDisplay`

- **没有进入声束：** 以上三个场景在 Authority 锚点到探头的实际水平距离检查时被排除，原因为 `outside_beam`。
- **被其它有效性条件排除：** 本次三条实测都不是这种情况。若发生，F3 会分别显示无效学校位置/水深、水面、海床净空、活动深度、目标不在探头下方、探测深度或斜距原因。
- **传感器有回波但 UI 未显示：** 用真实 Authority 学校构造声束内扫描后，P4.1 显示层读取同一历史样本；针对性测试确认当前列的一个回波到达 `SonarPlot.samples`。
- **画出但不明显：** 不是此次“靠近可见鱼但完全无变化”的主要原因，因为三条实测在传感器阶段就没有回波。当前诊断仍未在 Forward+ 屏幕上用真实回波确认其亮度观感。

## F3 定向诊断改动

- 每个扫描样本附带最多 16 个距探头最近的 Authority 学校几何诊断。它们从实际扫描循环收集，不运行第二次声呐扫描，也不更改扫描几何。
- 记录 School ID、物种、Authority 锚点、活动深度、水平距离、目标垂直距离/探头基准深度、该深度声束半径、斜距、有效深度上限，以及命中/排除原因。
- Fishing/Fish Finder F3 根据同一 School ID 调用 Renderer 只读诊断，显示当前渲染实例数、最近实例距锚点及距探头距离，并单独计算该最近可视点是否在声束内。
- 每次最多显示四个候选；优先显示当前有 Renderer 实例的学校。诊断双语本地化，不写高频日志。
- 可见实例超出探头 220 m 查询候选或来自其它水生视觉系统时，F3 标明无法映射，避免伪造学校身份。

打开 F3 → Fishing → Fish Finder 诊断，查看 `School <ID> ... MISS (outside cone footprint)` 及下一行 `Renderer instances ... visual-point test`。按一次现有“扫描鱼探仪”可以立即刷新诊断。

诊断脚本已写入项目，但当前已打开的 `Sea Prototype (DEBUG)` 进程不会自动加载这些文件改动；本轮没有关闭或重启它。要在真实画面查看，需手动重启项目后打开上述 F3 区域并触发一次扫描。

## 本轮修改与行为边界

- `scripts/fish_finder_sensor.gd`：在既有扫描循环中记录几何分项和排除原因；将原有声束判定以同等数学条件复用于诊断，不改 10° 半锥、220 m 斜距或 45 m 探测水深。
- `scripts/fish_school_renderer.gd`：只读扩充现有调试快照，返回已绑定学校 ID 的 Renderer 实例位置/offset；不改鱼的动作、分布、可见预算或 Authority 数据。
- `scripts/boat_hud.gd`、`scripts/fishing_debug_panel.gd`：将现有 Renderer 引用传给 F3 并展示诊断行。
- `resources/translations/fish_species.csv` 与导入翻译：新增英文和简体中文排除原因、学校及可视实例摘要。
- `tests/test_fishing_p4_1.gd`、`tests/test_surface_fish_visibility.gd`：添加声束内外、UI 获得回波、可视实例到学校映射、真实学校离锚点偏移、活动船探头切换及本地化断言。

扫描只读，不调用 population 变更，也不消费 Encounter RNG。P2 概率、鱼群数量、生成、活动行为、海床条件和声呐 UI 设计都未更改。

## 测试与视觉边界

- `godot --headless --path . --script res://tests/test_fishing_p4_1.gd`：PASS，包含真实扫描诊断和声束内外对照。
- `godot --headless --path . --script res://tests/test_surface_fish_visibility.gd`：PASS，针对针鱼、鲱鱼、海鳟分别取得实际 Renderer 实例/Authority 学校偏移并完成真实扫描；失败数 0。
- `godot --headless --path . --script res://tests/test_fishing_p2.gd`：PASS；覆盖扫描不改变 Authority 人口和 Encounter RNG。
- `godot --headless --path . --script res://tests/test_fishing_p4_2.gd`：PASS，P4.2 显示数据映射回归。
- `godot --headless --editor --path . --quit` 与 `git diff --check`：PASS。Headless 场景测试末尾出现现有 Renderer DummyShader RID 泄漏告警，不影响失败数/退出码；Headless 没有图形设备。
- **Forward+ 新 F3 诊断画面：NOT RUN。** 本轮没有重启现有游戏运行实例；headless 集成测试用于读取真实场景和实际扫描数据，不代替屏幕视觉检查。

## 结论及下一步

“开到肉眼可见鱼附近但鱼探仪没变化”的直接原因，是可见个体与 Authority 学校锚点之间存在米级偏移，而浅层 10° 向下声束的容许水平半径仅约 0.07–0.32 m；传感器按学校锚点聚合检测，因此鱼在屏幕上靠近船不代表学校锚点已进入船底声束。历史与 UI 对这些空扫描的表现符合预期。

F3 新诊断能在玩家现场确认当前具体 School ID 和排除原因。若要把声呐从“学校锚点统计回波”升级成能响应真实个体位置的声学呈现，下一阶段应先在不改变探测角的前提下评估将学校的视觉活动范围表示成有界的聚合回波体；那会改变 P4.1 的检测几何，未在本阶段实施。
