# P6.4.5.1 船钓自然中鱼机制重构报告

## 实施摘要

船钓自然中鱼现在分成两个互斥入口：鱼钩进入兼容鱼群的三维活动范围并满足钓组条件时，采用有上限的短反应时间后进入现有 Authority 预约和鱼类接近流程；鱼钩位于该范围之外时，才对附近合法 Authority 鱼群累计低概率现实时间 hazard。单钩和 Sabiki 都按真实钩位分别评估。拖钓候选判定、hazard、自动搏鱼与结算路径没有改动。

## 旧流程排查与回归判断

- 船钓候选查询原本已使用亮片钩尖或 Sabiki 各钩位的实际世界坐标，并每 0.5 现实秒评估一次；没有发现船中心替代钩位、串钩统一使用铅坠坐标或水深使用放线长度的回归。生产入口见 [boat_fishing_casting_system.gd:1291](/Users/smixu1/dev/boat-life-simulator/scripts/boat_fishing_casting_system.gd:1291)，查询间隔见 [boat_fishing_casting_system.gd:93](/Users/smixu1/dev/boat-life-simulator/scripts/boat_fishing_casting_system.gd:93)。
- 深度、兼容性、可用数量都在原 Authority 查询阶段检查。自然鱼仍先通过单钩或 Sabiki 的既有预约，再经过既有接近、确认中钩、搏鱼与结算；人口不会在开始接近时提前扣减。查询和候选资格见 [fishing_encounter_system.gd:286](/Users/smixu1/dev/boat-life-simulator/scripts/fishing_encounter_system.gd:286)，预约与确认见 [fishing_encounter_system.gd:774](/Users/smixu1/dev/boat-life-simulator/scripts/fishing_encounter_system.gd:774) 和 [fishing_encounter_system.gd:908](/Users/smixu1/dev/boat-life-simulator/scripts/fishing_encounter_system.gd:908)。
- 本轮没有确认 P6.4.4/P6.4.5 的位置或预约确认回归。此前玩家看到的 17.9 次/小时对应约 201 秒均值，和旧 hazard 的随机等待设计一致；主要问题是旧机制让正确找到鱼群后的中鱼仍依赖长时间随机事件，而不是一个已确认的坐标/生命周期故障。

## 新的触发流程

候选扫描分别计算鱼钩相对 Authority 鱼群代表位置的水平距离，以及钩位相对动态海面的实际水深和鱼群当前有效活动深度的垂直差。优先使用共享 WaveSampler 在鱼群位置采样海面；不可用时退回鱼群深度与传入钩深的差值，相关函数见 [fishing_encounter_system.gd:488](/Users/smixu1/dev/boat-life-simulator/scripts/fishing_encounter_system.gd:488)。

三维范围是沿用鱼种生态/渲染尺度的归一化椭圆：

```text
normalized_3d = sqrt((水平距离 / school_wander_radius)^2
                   + (垂直距离 / 垂直活动容差)^2)
垂直活动容差 = clamp(school_activity_radius * 0.7, 1.2, 3.0)
```

`normalized_3d <= 0.5` 为核心区，`0.5 < normalized_3d <= 1.0` 为边缘区，大于 1 为鱼群范围外。此判定没有扩大鱼群生态或视觉半径。候选查询仍限制在钩位水平 50 米；诊断面板可以额外查看至 65 米，但超出 50 米的鱼群不能进入任何自然触发模式。

定向资格需要：鱼种支持船钓、当前钓组兼容、Authority 有未预留自然鱼、鱼钩水深匹配，且动作满足要求。Sabiki 可静止等待；Single Jig 的相对水体速度须至少 0.04 m/s。定向反应参数集中在 Encounter Inspector：核心区总反应 2–5 秒，边缘区 5–10 秒。对浅水中鱼，系统会估算现有鱼类接近演出时长，从定向反应计时里扣除，避免把完整演出时长重复叠加；深水不强加可视化接近等待。反应计时、确定性变化和演出时长估算见 [fishing_encounter_system.gd:558](/Users/smixu1/dev/boat-life-simulator/scripts/fishing_encounter_system.gd:558) 与 [fishing_encounter_system.gd:655](/Users/smixu1/dev/boat-life-simulator/scripts/fishing_encounter_system.gd:655)。

已有接近一旦启动，不会因轻微越界立即取消：同一候选可在归一化距离 1.12 内保持，并有 1.25 秒边界宽限。切换到定向模式会清除该钩位 ambient hazard；离开候选范围或不再满足资格时则清理反应状态，避免两个模式累计或生成重复预约。

## 鱼群外偶遇

只有没有合格定向候选时才使用 `AMBIENT_ENCOUNTER`。偶遇仍须来自最多 50 米内的真实 Authority 鱼群，钓组兼容、鱼钩水深匹配、鱼群有可用资源；没有合法 Authority 学校时不会生成鱼，也不会发生偶遇。ambient 每个空钩独立以现实秒累计连续时间 hazard：

```text
单钩总事件率 = min(3 次/现实小时,
                    2 次/现实小时 * 最佳候选质量 * 密度轻微修正)
候选质量 = 鱼种 bite tendency * 深度权重 * 动作权重
           * 50 米水平权重 * 表层活动倍率
p(本时间步) = hazard threshold 的连续时间累计结果
```

多候选只按有限密度系数修正总率，然后按质量分配候选权重；不会按候选数直接线性叠加。ambient 的每钩基础率、上限、密度修正参数以及指数阈值累计见 [fishing_encounter_system.gd:45](/Users/smixu1/dev/boat-life-simulator/scripts/fishing_encounter_system.gd:45) 和 [fishing_encounter_system.gd:611](/Users/smixu1/dev/boat-life-simulator/scripts/fishing_encounter_system.gd:611)。

## Sabiki 与 Authority 生命周期

Sabiki 在同一自然判定周期内逐个检查 Hook 1–5 的实际钩位和深度；已挂鱼的钩位跳过，空钩仍逐一评估。玩家收线期间只要钩仍在水下，船钓状态仍会继续调用该检查。每次触发后立即经现有 `reserve_sabiki_hook()` 检查该鱼群人口减已预留数，避免多个钩位竞争同一尾鱼；同一钩位的反应与 hazard 状态以 hook index 分开存储。

确认中鱼后仍使用 P6.4.4/P6.4.5 的 participant、搏鱼、批量结算与取消释放流程。本轮不改 Authority 人口、reservation 消费、收获结算或拖钓状态机。单钩与每个 Sabiki 钩位调用入口见 [boat_fishing_casting_system.gd:1291](/Users/smixu1/dev/boat-life-simulator/scripts/boat_fishing_casting_system.gd:1291)；trigger 状态重置见 [fishing_encounter_system.gd:898](/Users/smixu1/dev/boat-life-simulator/scripts/fishing_encounter_system.gd:898)。

## F3 诊断

Fishing Debug 现在显示总触发模式、每个钩位的模式和阶段、候选 School ID、核心/边缘/范围外分类、水平与垂直差、归一化 3D 距离、可用数量、深度与动作资格、反应剩余时间及不能触发的原因。定向模式不再把旧 hazard 平均等待时间当主要指标；ambient 模式显示其事件率和统计平均等待时间。实现位置见 [fishing_debug_panel.gd:864](/Users/smixu1/dev/boat-life-simulator/scripts/fishing_debug_panel.gd:864)。新标签和失败原因加入 `fish_species.csv` 及 Godot 生成的中英文翻译资源。

## 数值案例

以下均使用当前默认生态尺度、钩深和配置，给出时间范围或统计均值，不是保证倒计时。

| 场景 | 计算 | 结果 |
|---|---|---|
| 鲱鱼核心区 | 鲱鱼默认水平游荡半径 2.4 m；钩位距鱼群中心 1.0 m、垂直差 0 m，归一化距离 `1/2.4 = 0.417`，属于核心。Sabiki 兼容且有可用鱼。 | `SCHOOL_TARGETED`，总反应参数 2–5 秒。浅水既有接近演出估算为 3.6 秒，因此实际从进入核心到完成咬钩约为 3.6–5 秒。 |
| 鲱鱼边缘 | 距离 2.16 m、垂直差 0 m，归一化距离 `2.16/2.4 = 0.90`，属于边缘。 | `SCHOOL_TARGETED`，总反应 5–10 秒；既有浅水接近演出仍计入总时间，不再额外叠加。 |
| 鲱鱼范围外、但距真实学校 3 m | 垂直差 0 m，归一化距离 `3/2.4 = 1.25`，在三维活动椭圆外；距学校小于 10 m，水平权重 1。静止 Sabiki 动作权重 0.8，表层活动倍率 1.6，鲱鱼 bite tendency 默认 1.0，故质量 `1.0*1.0*0.8*1.0*1.6=1.28`，事件率 `2*1.28=2.56/小时`。 | `AMBIENT_ENCOUNTER`，统计均值 `3600/2.56 = 1406 秒 = 23.4 分钟`。超过 50 m 或无 Authority 学校时事件率为 0。 |

上述核心/边缘分类和偶遇概率由定向测试覆盖；ambient 27.6 分钟案例（鲱鱼位于 15 m、其余条件相同）还由 P6.3.3 测试输出直接验证。

## 测试结果

执行并通过：

- `godot --headless --path . --editor --quit`：脚本与资源导入/解析完成，无本次改动相关解析错误。Godot 输出已有重复翻译 UID 提示及退出时对象泄漏警告；不作为功能通过依据。
- `godot --headless --path . -s tests/test_p6_4_5_1_boat_fishing_bite_rework.gd`：核心/边缘定向、ambient 限制、错水层/动作/兼容性、50 米查询边界、Sabiki 独立钩位与 Authority 数量限制、现实时间累计、模式切换清理通过。
- `godot --headless --path . -s tests/test_p6_3_1_single_jig.gd`：真实 Authority 单钩接近、确认、搏鱼和结算闭环通过。
- `godot --headless --path . -s tests/test_p6_3_2_sabiki_multi_catch.gd`：Sabiki 五钩预约/批次、自然判定和 F3 回归通过。
- `godot --headless --path . -s tests/test_p6_3_3_bite_experience.gd`：深度与距离经验回归及 ambient 现实时间模型通过；测试报告 ambient `2.18/h`、均值 `27.6` 现实分钟。
- `godot --headless --path . -s tests/test_p6_4_2_boat_fishing_fight_model.gd`、`test_p6_4_3_boat_fishing_fight_solver.gd`、`test_p6_4_5_boat_fishing_visual_motion.gd`：P6.4.2 participant、P6.4.3 solver 与 P6.4.5 空间/视觉逻辑回归通过。
- `godot --headless --path . -s tests/test_fishing_p3_2.gd` 和 `tests/test_fishing_p3.gd`：拖钓调试隔离、自然钩中、原自动演出、渐进收线、结算和恢复拖钓通过。`test_fishing_p3.gd` 有 Bathymetry 无 ShaderMaterial 的 Headless 警告，但测试最终 `failures=0`。
- `git diff --check`：通过。

这些为 Headless 代码和逻辑测试。本轮没有在 GPU 图形场景里人工检查实际鱼群、F3 面板或咬钩画面；不能据此宣称完成了实际画面验收。建议人工验收：进入 F3 → Fishing，分别将单钩/串钩真实钩位放入兼容鱼群核心和边缘、置于错水层、再移出鱼群范围；核对诊断模式、Hook 1–5 状态及接近演出。再到无附近 Authority 鱼群处确认不会生成偶遇鱼。

## 修改文件

- `scripts/fishing_encounter_system.gd`：船钓候选空间资格、双触发模式、短反应状态、边界保持、ambient hazard。拖钓现有 `evaluate_candidates()` 与 hazard 路径未改。
- `scripts/boat_fishing_casting_system.gd`：单钩与 Sabiki 每钩实际位置调用新触发 API，保留现有预约确认流程并汇总诊断。
- `scripts/fishing_debug_panel.gd`、`resources/translations/fish_species.csv`、`resources/translations/fish_species.en.translation`、`resources/translations/fish_species.zh_CN.translation`：F3 诊断和本地化。
- `tests/test_p6_4_5_1_boat_fishing_bite_rework.gd`：新增双模式、三维距离与时间测试。
- `tests/test_p6_3_1_single_jig.gd`、`tests/test_p6_3_2_sabiki_multi_catch.gd`、`tests/test_p6_3_3_bite_experience.gd`：将过时的“船钓只用旧 hazard”断言改为新目标/ambient 机制回归。

## 限制与后续注意

- 核心/边缘椭圆采用各鱼种已有 `school_wander_radius_m` 和 `school_activity_radius_m` 的派生容差；若未来调整这些生态视觉尺度，目标中鱼范围会随之改变，需要一并平衡。
- Ambient 有意只从 50 米查询内的真实 Authority 学校抽取合法鱼。当前 Authority 不提供全海域无学校时的自然个体来源，因此远离所有学校的空海域不会发生偶遇；这是遵守不伪造鱼和 Authority 单一权威的限制。
- Single Jig 在鱼群定向区域须达到 0.04 m/s 相对水体运动；Sabiki 静止等待仍有效。若现场玩家动作反馈不清楚，先看 F3 的动作资格与实际相对速度。
- 确定性反应变化按 school ID、hook index 和船钓触发会话生成，ambient hazard 使用独立船钓 RNG；都不影响拖钓 RNG/计时。
- 实际 Forward+ 场景及 F3 可读性仍待人工画面验收。
