# P6.4.5.3.2a — 现有鱼群三态视觉系统审计与增量优化

## 现状结论

- Authority 已拥有唯一的 `CALM / ALERT / FLEEING` 状态及连续惊扰值；状态随鱼群快照序列化。入口在 `scripts/fish_local_authority.gd:131`，状态字段在 `scripts/fish_school_state.gd:32`。
- Renderer 已有完整的普通群游、警觉、逃散和恢复表现。它读取 Authority 状态，按鱼种行为类型映射为本地视觉响应；不会反向修改 Authority 状态或位置。
- 发现一个真实的视觉跳变：Authority 从 FLEEING 直接回到 ALERT 时，视觉扩散半径立即归零；已经扩展到普通半径之外的个体会被一次性夹回。对 stickleback 的有效测试状态，该实现会把扩展边界从 3.2 m 立即收回；本次改为平滑收缩，单个 0.16 s 更新步的边界收缩为 0.40 m。
- 没有重写三态系统，也没有修改 Authority、鱼探仪或捕鱼资格。未做 GPU 实机验收。

## 三态行为及所有权

Authority 在 `FishLocalAuthority.update_school_disturbance()` 中更新惊扰级别、目标值、三态、持续强扰动时间和咬钩意愿（`scripts/fish_local_authority.gd:131–195`）。模型负责阈值滞回和状态推进；`FishSchoolState` 保存同一份状态供快照恢复。没有发现 Renderer 另行根据船距决定进入 ALERT 或 FLEEING 的逻辑。

Renderer 通过 `get_schools_near()` 取得 Authority 学校快照（`scripts/fish_school_renderer.gd:532`），在 `_build_school_fish()` 读取其三态和惊扰级别（`:850–860`）。当前视觉行为如下：

- **CALM**：继续使用已有个体随机初始位置、速度、常规转向/巡游、邻近分离、对齐与内聚；表层鱼继续使用现有活动深度周期。
- **ALERT**：使用现有局部 alert 响应、更强的内聚/对齐，并增加朝扰动来源方向的低幅转向；不会变成 FLEEING。
- **FLEEING**：映射为视觉 `scattering` / `flee`，提升允许游速，增加逃离加速度并扩展本地队形。沿海底栖鱼使用已有的逃散深度目标；表层鱼保持其物种的垂直活动约束。
- **恢复**：Authority 回到 CALM 后，Renderer 以既有 `recovering` 呈现阶段逐步增加内聚并缩回队形。该本地阶段只负责视觉过渡，不会重新计算 Authority 惊扰，也不会影响咬钩倍率。

状态切换不会直接重置鱼的位置或速度；原有 AI 更新周期约 0.16 s，渲染帧通过存储的起止 Transform 插值。发现的跳变来自**队形半径限幅值瞬间变小**，不是鱼群中心或个体速度重置。

Renderer 中的 `disturbance_state`、`scattering` 和 `recovering` 是 Authority 状态的展示映射与恢复缓冲，不是另一个惊扰来源。`stickleback_alert_radius_m` 与 `surface_fish_alert_radius_m` 只参与已获 Authority 状态后的逃离方向权重，不负责触发状态。旧的基于 Renderer 自行扫描威胁并计算惊扰状态的代码在当前实现中不再执行；`_build_school_fish()` 尚留一个无使用的 `disturbance_sources` 可选参数，本次未做无关签名清理。

## 位置关系、声呐与追饵

`FishSchoolState.world_position` 是共享 Authority 学校锚点。Renderer 以该位置为中心，将每条视觉鱼的本地偏移加到锚点并只更新自己的实例 Transform（`scripts/fish_school_renderer.gd:849` 及 `:1136` 后）；没有将个体偏移写回管理器。表层鱼还会在 Renderer 内对快照副本做平滑预测，不会回写 Authority。

因此，声呐和 FishingEncounter 有意查询学校代表锚点，而不是逐个视觉实例：声呐在 `scripts/fish_finder_sensor.gd:170–181` 查询学校并以锚点和配置半径构造学校代理；FishingEncounter 在 `scripts/fishing_encounter_system.gd:380` 起读取同一学校位置并以其活动中心做资格判断。FLEEING 时个体可在该代表点周围分散，这是预期的“个体视觉偏移”，不会移动 Authority 学校、声呐扫描原点或 FishingEncounter 中心。

对于目前船钓目标鱼，配置的追饵球覆盖视觉最外层散开范围：鲱鱼的默认队形半径约 2.4 m，加 5 m × 0.85 的散开延伸，约 6.65 m，小于 12 m 追饵半径；海鳟约 5.2 + 4.25 = 9.45 m，小于 16 m；针鱼约 9.45 m，小于 14 m。三维垂直分散也远小于这些余量。因此没有发现 FLEEING 的视觉散开会单独把可见目标鱼排除在追饵球之外。

声呐仍显示学校级代理，不会逐个显示散开的视觉鱼；FLEEING 时视觉分布可能比声呐代理的核心半径更宽。这是当前聚合声呐表示与个体视觉散开的尺度差异，未发现本次改动会影响探测中心或已配置目标鱼的追饵资格。按本阶段范围未调整声呐表现；若实机观察到鱼群散开后回波明显窄于视觉群体，应在单独的声呐任务中评估代理半径是否应读取 Authority 惊扰状态。

## 本次最小修改

在 `scripts/fish_school_renderer.gd:28` 增加一个可调的纯视觉扩散半径响应速度，默认 `2.5 m/s`。原有 ALERT、FLEEING 和 recovering 仍各自计算原来的目标扩展值（`:1121–1132`）；现在将每条鱼已显示的扩展半径以 `move_toward()` 平滑追随该目标（`:1136–1138`），再用于原有活动半径和位置限幅。

Authority 状态和惊扰参数不变；CALM/ALERT/FLEEING 不新增、不复制。修改只在既有低频逐鱼更新中读取/写入一个标量并执行一次 `move_toward()`，没有新 Node、实例、循环或每帧扫描。保留既有 MultiMesh、LOD、可见性和渲染帧插值。

## 测试与验证

扩展 `tests/test_fish_resources.gd` 覆盖 CALM 不因船位直接逃散、Authority ALERT 显示 alert 且不误入 flee、Authority FLEEING 触发逃散、恢复 CALM 后完成群体恢复，并用有效的外围 stickleback 个体检查 FLEEING→ALERT 的连续位移。

- `godot --headless --path . --script tests/test_fish_resources.gd` — 通过，0 failures。FLEEING→ALERT 合成有效状态下，0.16 s 的观测位移为 0.40 m；Renderer-only 更新后 Authority 锚点保持不变。
- `godot --headless --path . --script tests/test_p6_4_5_3_1_school_disturbance.gd` — 通过，0 failures；Authority 的空间惊扰和三态模型未改。
- `git diff --check` — 通过。

Headless 测试不验证 GPU 画面，也不能代替实际渲染验收。退出时出现 Dummy Renderer shader RID 泄漏提示，测试进程退出码为 0，断言全部通过。

## GPU 检查建议与后续边界

实机建议观察同一鱼群从 CALM → ALERT → FLEEING → ALERT → CALM：特别留意 FLEEING 回到 ALERT 时外围鱼是否逐渐回收、鱼群中心是否保持连续、以及恢复期是否平滑。再对照鱼探仪回波和 F3 的 Authority 锚点/视觉最远偏移，确认学校代理半径差异是否能被玩家感知。

P6.4.5.3.2b 若接入离群追饵鱼视觉，应继续把“鱼群锚点与群内实例偏移”同“独立追饵实体”分开管理：Renderer 的散开鱼仍归原 School；追饵鱼的挂钩和 Authority pending 生命周期继续由 Casting/Encounter 持有，不能被群内 MultiMesh 重建或状态恢复覆盖。本阶段未修改这条所有权边界。
