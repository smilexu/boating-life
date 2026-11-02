# P6.3.3 — 船钓中鱼体验优化报告

## 修改摘要

- `scripts/fish_school_state.gd`：为鱼群活动深度记录最近一次 Authority 深度检查点时间。
- `scripts/fish_local_authority.gd`：快照增加连续投影后的有效深度、目标深度和活动状态；保留原有 8 秒生态步进。
- `scripts/fish_species_profile.gd`：集中定义生态状态对应的表层视觉指示条件，供 Renderer 与中鱼倍率共同使用。
- `scripts/fish_authority_adapter.gd`、`scripts/fish_resource_manager.gd`：将“包含已耗尽鱼群”的可选只读查询参数传到 Authority，供 F3 诊断解释候选缺失原因。
- `scripts/fish_school_renderer.gd`：鱼群渲染、可见性判断和调试代表深度改用 Authority 快照中的有效深度。
- `scripts/fishing_encounter_system.gd`：校准船钓现实时间 hazard、表层活动系数与距离权重参数；中鱼评估消费连续有效深度。
- `scripts/boat_fishing_casting_system.gd`：船钓 hazard 按实际经过时间累计，维持 0.5 秒采样；F3 读取低频缓存，并仅在诊断请求时额外查询。
- `scripts/fishing_debug_panel.gd`、`resources/translations/fish_species.csv`：在 F3 Fishing 显示船钓中鱼诊断；新增的 CSV 翻译已由 Godot 重新导入。
- 定向测试：`tests/test_p6_3_3_bite_experience.gd` 新增；同步了 `tests/test_p6_3_1_single_jig.gd`、`tests/test_p6_3_2_sabiki_multi_catch.gd` 对现实小时率和当前距离曲线的断言；`tests/test_fish_population_recovery.gd` 改为验证持久化 Authority 状态，避免把动态有效深度投影与静态存档快照混为一谈。

## 1. 鱼群深度一致性

### 原因

鱼群的表层/深层活动状态由 `FishLocalAuthority` 以 8 秒为一个生态检查步长推进（`scripts/fish_local_authority.gd:13,64-77`）。旧的渲染和中鱼消费者都直接读检查点 `activity_depth_m`；渲染端会平滑移动个体，而自然中鱼查询在检查点刚更新时立即采用新深度。因此两次检查之间最多可能出现约 `垂直速度 × 8 秒` 的代表深度差。鲱鱼的配置速度约为 0.75 m/s 时，一次检查可跨约 6 m。

### 修复

- `FishSchoolState` 新增 `activity_depth_state_timestamp_seconds`，并在 schema 3 快照中序列化；旧快照没有该字段时，以原快照模拟时间初始化，保持兼容（`scripts/fish_school_state.gd:22,51,83`；`scripts/fish_local_authority.gd:198-217`）。
- Authority 在生成鱼群时设置检查点时间；每个原有生态检查步只把连续投影结果写回一次（`scripts/fish_local_authority.gd:464-480`）。
- 读取单个/附近/全部鱼群快照时，Authority 从检查点按活动状态、剩余停留时间、目标深度和 `activity_vertical_speed_mps` 投影当前有效深度。投影同时处理停留结束、上潜、下潜和状态切换；原始 `activity_depth_m` 与目标仍单独保留（`scripts/fish_local_authority.gd:79-104,483-553`）。
- 鱼群 Renderer 使用 `effective_activity_depth_m` 和 `effective_surface_activity_state` 作为渲染输入（`scripts/fish_school_renderer.gd:1501-1505` 及其深度调用点）。自然中鱼评估使用同一快照字段（`scripts/fishing_encounter_system.gd:284-302`）。规则输入不依赖 GPU 实例、相机可见性或画质。
- 投影只计算活动状态和深度，不调用生态迁移、鱼群生成、海底采样或逐鱼 AI。Renderer 仍按既有约 0.16 秒可视更新周期读取附近鱼群快照；自然判定仍每 0.5 秒检查一次。

### 水深定义

活动深度仍表示相对当前水面基准的水下深度；水面高程采样方式没有改变。单钩使用亮片实际位置算得的深度，串钩五个空钩各自使用其世界位置和动态水面高度计算深度（`scripts/boat_fishing_casting_system.gd:1093-1185`）。不以放线长度代替垂直深度。鱼群水层比较使用 Authority 的代表有效活动深度，不读取渲染数据。

## 2. 自然中鱼率与时间语义

船钓保持 hazard/指数阈值累计，不使用固定倒计时或每采样点独立掷固定概率。事件率换算为现实小时，按 `rate_per_real_hour × elapsed_real_seconds / 3600` 累加。串钩每个空钩保留独立阈值与 hazard 累计，实际中鱼仍须通过候选兼容检查与 Authority reservation。

- 单钩基础率：`60 次/现实小时`。
- Sabiki 单个钩位基础率：`50 次/现实小时`。
- 单钩动作权重：静止下限 0.55，随相对速度线性升至 1.0，参考速度 2.5 m/s。
- Sabiki 动作权重：静止下限 0.8，随相对速度线性升至 1.0，参考速度 2.5 m/s。
- 数量权重：`min(sqrt(当前可用数量 - 已预留数), 3)`。表层倍率不再重复使用数量作为密度加成。
- 水深权重：以当前有效代表深度与钩位深度之差为输入；容差为 `clamp(school_activity_radius_m × 0.7, 1.2, 3.0)`，在容差的 35% 以内为满权重，之后用 smoothstep 衰减至零。
- 单钩和 Sabiki 的基础率、动作权重仍然分开。

候选率公式为：

```text
每个钩位事件率 = 钓组基础率
               × 鱼种相对咬钩倾向
               × 可用鱼群数量权重
               × 水平距离权重
               × 水层权重
               × 动作权重
               × 表层活动倍率
```

实现位置：参数在 `scripts/fishing_encounter_system.gd:39-52`；候选权重和事件率在 `:269-356`；独立 hazard 累计在 `:418-448`；船钓现实 delta 与 0.5 秒采样在 `scripts/boat_fishing_casting_system.gd:1093-1107`。自定义 World Time 倍率（默认 24×，`scripts/world_time_state.gd:8,14`）只影响游戏日夜时间；船钓咬钩节奏现在用 Godot 处理帧提供的实际经过 delta，不乘游戏时间倍率。拖钓仍使用原来的游戏时间模型。

## 3. 表层活跃倍率与距离

表层活动系数只使用 Authority 的生态状态、有效活动深度及鱼种配置，不看屏幕、画质或渲染开关（`scripts/fishing_encounter_system.gd:391-400`）。显著表层指示条件由 `FishSpeciesProfile.is_surface_activity_visually_indicated` 集中提供：鱼种启用表层活动循环、活动状态为 near-surface/ascending/descending 且有效深度不大于 2 m；Renderer 使用同一条件决定表层鱼群记录（`scripts/fish_species_profile.gd:7,118-123`；`scripts/fish_school_renderer.gd:711-713,736-747`）：

| 状态 | 系数 |
|---|---:|
| 普通深水 | ×1.0 |
| 表层循环中未满足 ≤2 m 指示条件，但仍在逻辑表层阈值内 | ×1.2 |
| 满足共享的表层指示条件（活动深度 ≤2 m，活动状态为 near-surface/ascending/descending） | ×1.6 |

表层循环中的 near-surface/ascending/descending 学校若仍在逻辑表层阈值内但不满足 ≤2 m 指示条件，使用较低 ×1.2。这样不会把水下较深但可渲染的鱼群都当成水面鱼群。生态数据没有单独、可信的“密集活跃”级别，所以没有加 ×2.0；使用鱼群可用数量权重表达数量影响，避免密度重复放大。水层权重为零时，活动倍率不能使候选变为有效中鱼。

水平判定依然使用真实钩位/亮片与鱼群 Authority 位置之间的水平距离。50 m 是自然候选查询与有效范围，50 m 处及以外权重为零。现有曲线未改：0–10 m 为 1；10–20 m 从 1 线性降到 0.70；20–35 m 从 0.70 降到 0.25；35–50 m 从 0.25 降到 0。默认节点实测为 5 m=1.00、15 m=0.85、25 m=0.55、35 m=0.25、45 m≈0.083、50/55 m=0。未扩大鱼群生态半径、探鱼器范围或拖钓距离模型。

## 4. F3 Fishing 诊断

F3 面板每 0.5 秒刷新，且面板不在树上可见时直接停止刷新（`scripts/fishing_debug_panel.gd:289-296`）。自然中鱼关闭 F3 时不会增加额外查询。诊断请求复用相同候选评估；最多对空钩查询一次，并仅读取本地 Authority 空间索引中的邻近区域。F3 的诊断半径是 65 m，且可包含 depleted/reserved 学校；这只是为了显示“鱼群在附近但超过 50 m”或“鱼群已无可用鱼”，不会改变自然中鱼的 50 m 查询。

显示内容包括：钓组/状态、线长、相对水速、空钩数量、亮片深度或逐钩深度与状态；候选行显示 school/species、人口与 reservation、水平距离及权重、Authority 目标/有效深度、鱼饵与有效深度差、水层权重、数量权重、动作权重、表层倍率、基础率和最终率，以及被拒绝原因。Renderer 若已有对应鱼群个体数据，还显示可见代表深度及与有效深度的差；这只用于诊断，不进入概率规则。字段组在 `scripts/fishing_debug_panel.gd:864-940`，双语文案在 `resources/translations/fish_species.csv:859-884`。

诊断原因可区分：没有邻近候选、钓法/钓组不兼容、资源不足、超过 50 m、水层不匹配、动作权重过低、候选有效但 hazard 尚未达到、鱼群冷却和中鱼已开始。

## 5. 首次咬钩统计

执行 `tests/test_p6_3_3_bite_experience.gd`：固定候选条件、10,000 次独立指数阈值抽样、以 0.5 秒检测间隔量化；观察窗口 120 秒。该统计用于校准 hazard 的首个事件时间，不运行完整 3D 场景中的鱼群运动或每次结算。串钩行的总率为五个空钩当前事件率之和；“仅两条鱼”行只估计第一条中鱼发生前的 hazard，随后可挂数量仍受 Authority reservation 限制。

| 条件 | 总事件率 | 首次中鱼中位数 | P90 | 120 秒未中比例 |
|---|---:|---:|---:|---:|
| 表层 Sabiki，5 m，匹配水层，64 条可用鲱鱼 | 960/h | 3.0 s | 9.0 s | 0.00% |
| 表层 Sabiki，15 m，匹配水层 | 816/h | 3.5 s | 10.5 s | 0.00% |
| 表层 Sabiki，30 m，匹配水层 | 384/h | 7.0 s | 22.0 s | 0.00% |
| 深水 Sabiki，15 m，匹配水层 | 510/h | 5.0 s | 16.5 s | 0.00% |
| 表层 Sabiki，错误水层 | 0/h | 无 | 无 | 100.00% |
| 不兼容 Sabiki/鱼种 | 0/h | 无 | 无 | 100.00% |
| 表层 Sabiki，仅 2 条可用鲱鱼（第一条事件） | 452.55/h | 5.5 s | 18.5 s | 0.00% |
| 表层单钩，10 m，海鳟匹配水层 | 142.56/h | 17.0 s | 56.5 s | 0.90% |

数值是该固定参数样本的分布，不是保证倒计时。自然咬钩判定与浅水鱼接近演出分开：当前 0.5 秒周期用于发现并确认自然事件；浅水接近和接触鱼钩所需时间不计入上表，演出逻辑保持不变。

## 6. 定向验证结果

- `godot --headless --path . --editor --quit`：Godot 4.7.2 成功导入翻译 CSV 并注册脚本。输出了仓库中其他 Polar telemetry 翻译资源的重复 UID 警告和退出时 ObjectDB 泄漏警告。
- `godot --headless --path . --script res://tests/test_p6_3_3_bite_experience.gd`：通过，`failures=0`。覆盖距离曲线、表层倍率、50 m 自然范围与 65 m F3 范围、55 m 不产生 hazard、半秒真实时间 hazard、Authority 连续深度、渲染/中鱼有效深度一致性，以及上述统计场景。
- `godot --headless --path . --script res://tests/test_p6_3_1_single_jig.gd`：通过，`failures=0`。覆盖单钩 Authority 候选、浅水演出、自动收鱼、结算和 debug fish 隔离。
- `godot --headless --path . --script res://tests/test_p6_3_2_sabiki_multi_catch.gd`：通过，`failures=0`。覆盖五钩资源约束、挂鱼累积、批量收鱼和结算。
- `godot --headless --path . --script res://tests/test_surface_fish_visibility.gd`：通过，`failures=0`。覆盖表层鱼群 Renderer、Authority 与声呐显示回归。

Headless 输出包含 dummy renderer 的 null material/RID 退出日志；断言均通过。未进行实际画面下的鱼群深度人工观测或听感测试，也未运行完整测试矩阵。

## 7. 性能与已知限制

- 不新增逐鱼追饵 AI，不改变 8 秒 Authority 生态步进，也不新增海面/海底查询。
- 连续深度是对快照中少量活动状态数据做纯逻辑投影；Renderer 每次原有附近鱼群更新时使用投影快照。未测量设备帧时性能，因此不报告帧率或耗时基准。
- F3 开启时的诊断扫描频率为 0.5 秒；关闭时不执行这些额外查询。
- 咬钩仍为每 0.5 秒的当前位置采样，没有实现轨迹积分。快速收线可能在两次样本之间穿过高权重位置；本轮未引入用户明确排除的连续轨迹检测。
- 统计测试使用固定有效水层/距离/种群的模型条件，不模拟鱼群漂移、资源随连续挂鱼而减少及鱼接近演出的耗时。真实运行中候选率会随鱼群移动、活动深度和 reservation 改变。
- “平均等待”是当前指数 hazard 的均值，不是下一次咬钩的保证时间；F3 会显示随机事件尚未触发。
- 拖钓 hazard、距离、鱼群生成和恢复、鱼探器、装备兼容、经济及全局世界时间倍率均未调整。
