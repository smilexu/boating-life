# P6.4.5.3.2a.2 — 表层鱼船周硬剔除移除与视觉运动连续性修复

## 修改结果

移除了表层活动鱼在船中心 5m 水平圈内被直接剔除的行为。`herring`、`sea_trout` 和 `needlefish` 现在继续生成正常的 Renderer 鱼记录，因此 MultiMesh 的活动 key 不会仅因靠近船而消失，个体的游动、FLEEING、扩散半径和 Transform 插值状态能够跨越该区域继续更新。

三刺鱼 `coastal_benthic` 分支没有改动：通常仍使用 0.65m 局部排除；FLEEING 或 F3 水下观察时仍将排除设为 0。未新增船体避让。

## 修改文件

- `scripts/fish_school_renderer.gd` — `_build_school_fish()` 中按配置计算 clearance 后，将 `surface_activity_cycle_enabled` 学校的 clearance 置零。保留原来的表层运动和三态映射。`boat_exclusion_radius_m` 保留为非表层、非底栖通用 Profile 的回退配置；目前注册的三个表层目标鱼不再使用它。
- `tests/test_fish_resources.gd` — 加入三种表层鱼的受控穿越检查：船在个体外 6m、进入旧 5m 圈、再离开；跟踪同一 key 的记录、状态标记、FLEEING 表现、扩散状态和世界 Transform。测试的状态保留辅助函数只用于模拟生产代码按活动 render key 清理状态，不影响游戏代码。
- `P6_4_5_3_2A2_BOAT_EXCLUSION_FIX.md` — 本报告。

没有修改 Authority、School 状态、生态人口、声呐、FishingEncounter、捕鱼状态机、鱼种参数或三刺鱼专用逻辑。

## 原剔除路径与现在的行为

原逻辑在 `FishSchoolRenderer._build_school_fish()` 中对非底栖鱼使用 `boat_exclusion_radius_m=5.0`。个体水平距离船中心不足 5m 时直接 `continue`；该鱼不进入当前 `fish_records`。外层 `_update_visible_fish()` 按 records 数量提交 `MultiMesh.instance_count` / `visible_instance_count`，并删除不在活动 key 中的 `_individual_states`（`scripts/fish_school_renderer.gd:630–652`）。下次进入记录列表时，该个体只能由 seed 初始化，因此运动上下文丢失。

修改后，表层活动鱼在该位置条件前把 clearance 设为 0，既不因船中心距离跳过记录，也不会由此触发实例数缩减和本地状态清理。它仍然经过现有水深、最小水柱、位置限幅、朝向和 transform 更新。物理船体或水面可能遮住实例的像素，但那属于正常几何渲染；本次没有增加额外隐藏或避让系统。

`boat_exclusion_radius_m` 没有删除：代码仍把它作为非表层、非底栖通用鱼 Profile 的可配置回退（Renderer 顶部配置和 clearance 赋值处）。当前默认注册的四种鱼里，该回退不适用于三种表层目标鱼；三刺鱼继续使用单独的 0.65m 值。

## 三态行为、状态连续性与实例影响

Authority CALM / ALERT / FLEEING 映射、Renderer alert/scattering/recovering 运动、内聚/对齐/分离、个体游速与转向均未改动。P6.4.5.3.2a 的 `visual_scatter_radius_response_mps=2.5` 也未改动。没有新增逐帧循环、节点或状态机。

近船时 MultiMesh 可能比旧行为多保留一些实例，这是移除硬剔除的预期结果；每种鱼仍沿用现有物种预算、全局 `maximum_visible_fish` 上限和一个 MultiMesh 批次。未运行 GPU 性能基准，未测量实例数量差值或毫秒变化。Headless 定向测试确认三个物种在受控单鱼场景中的 records 数量分别为船外 1、原 5m 圈内 1、离船后 1；同一 state marker 保留，FLEEING 行为、半径平滑和 Transform 更新继续发生。

三刺鱼的 0.65m clearance 与 FLEEING / observation 豁免代码未改变。现有 `test_fish_resources.gd` 的底栖水深、状态行为和 F3 水下观察断言仍通过；本轮没有添加另一套三刺鱼算法。

## 测试结果

- `godot --headless --path . --script tests/test_fish_resources.gd` — 通过，`failures=0`。新增 Herring、Sea Trout、Needlefish 三个受控穿越检查全部通过；旧 5m 圈内仍有 record，个体状态标记和移动 Transform 连续，离开后未重新初始化。
- `godot --headless --path . --script tests/test_p6_4_5_3_1_school_disturbance.gd` — 通过，`failures=0`。CALM / ALERT / FLEEING Authority 状态回归通过。
- `git diff --check` — 通过。

Headless 进程在退出时仍报告 Dummy Renderer shader RID 清理提示；测试退出码为 0，断言全部通过。该提示不等同于 GPU 渲染失败，也不能证明 GPU 画面已正确。

## GPU 实机验收与剩余风险

本轮没有 GPU 实机验收。请在正常图形运行中用浅层 Herring School 和低速船按“接近 → 进入旧 5m 区域 → 穿过中心 → 驶离”观察：固定圆形空洞是否消失、同一批鱼是否连续移动、是否还有突现/消失、船体遮挡是否自然。再对照 Sea Trout 和 Needlefish。

本次成功修复的是已确认的 CPU 侧记录硬剔除和由此造成的 state 清理。船底/船舷与鱼体真实几何相交时，模型仍可能被船体遮挡或发生视觉穿模；没有根据当前信息增加船体避让。若修复后仍看到局部缺鱼，应同时检查 F3 `visualized_fish` / `visible_fish` 与 GPU 像素：实例记录存在而像素消失时，再按船体、水面深度和 GPU 遮挡单独取证。
