# P6.3 钓鱼中鱼机制专项审查：水层匹配与运动轨迹

## 审查范围与方法

本报告只做静态代码审查。未修改代码、资源、测试或参数；未运行测试或游戏。结论反映当前脚本默认值和调用关系。游戏运行时的具体鱼群 `activity_depth_m`、波浪高度和当前帧间隔未从现场遥测读取，相关处会标为待确认。

## 结论摘要

玩家把亮片抛到鱼群后方再收线时，系统确实会在亮片经过鱼群附近时检查中鱼，但它不是沿整段轨迹连续检查：等待状态下默认每 0.5 秒只用当前亮片/钩位位置查询一次鱼群，并把这次位置的中鱼率用于上一个采样间隔累计的游戏时间。没有保存或检测两个采样点之间的路径。

目前最值得注意的限制有两个：

1. **水深匹配不是“鱼饵是否落在鲱鱼表层活动范围 0.7–2.5 米内”的区间判断。** 鲱鱼 Authority 每一群只提供一个当前活动深度标量；中鱼系统把鱼饵深度与这个标量比较，再在约 1–3 米范围内衰减。`minimum_depth_m = 8` 是海床生境深度，不能解读为鱼在水下 8 米。
2. **可见鱼群深度和中鱼所读深度可能短时不同步。** Authority 的活动深度每个 8 秒模拟步更新一次；渲染中的鱼个体则每帧以设定的垂直速度追逐 Authority 深度。代码因此允许可见个体仍处在较浅位置，而捕获判定已经读取新的、较深的群体深度。这个问题比普通 0.5 秒水平采样间隔更可能解释“看见表层鱼，却拖饵穿过没有咬”的体验，但具体现场是否命中该情况，需读取当时的 Authority 深度才能确定。

对题目给定的 0.5、1.5、3.0 m/s 水平速度，默认每次中鱼位置采样之间约移动 0.25、0.75、1.5 米。相比水平权重的 10 米分段，这种稳定运行下的纯水平漏采风险不高；抛竿后收线穿过区域**不是必定漏判**，但也绝不保证中鱼，因为中鱼率仍然较低且随机。建议采用方案 C 对明显移动/深度变化的区间进行有限自适应采样，同时优先核实和协调 Authority 深度与画面鱼深。C 能改善轨迹积分，但不能单独修复水深输入不同步。

## 1. 当前实际中鱼调用链

1. `BoatFishingCastingSystem._process()` 在 `WAITING` 与 `SABIKI_HOOKED_WAITING` 中更新鱼饵运动，然后调用自然中鱼检查；单钩和串钩都只在这两种等待状态检查。见 [`scripts/boat_fishing_casting_system.gd:961-985`](scripts/boat_fishing_casting_system.gd#L961)。
2. `_update_natural_bite_judgement(delta)` 要求鱼饵已落水，累计进程时间和世界游戏时间；默认累计到 0.5 秒才执行一次位置检查。见 [`scripts/boat_fishing_casting_system.gd:1039-1058`](scripts/boat_fishing_casting_system.gd#L1039)。
3. 单钩以 `_bait_world` 和当前动态水面下的实际深度调用 `evaluate_boat_fishing_candidates()`。串钩先取当前五个钩位坐标，跳过状态不为 `empty` 的钩位，然后对每个空钩分别采样深度并调用同一个候选评估函数。五钩共用坠子的相对速度值。见 [`scripts/boat_fishing_casting_system.gd:645-664`](scripts/boat_fishing_casting_system.gd#L645) 和 [`scripts/boat_fishing_casting_system.gd:1059-1090`](scripts/boat_fishing_casting_system.gd#L1059)。
4. 候选评估查询 50 米内 Authority 鱼群，依次计算兼容性、资源数、水平距离权重、活动深度权重、动作权重及每小时事件率。见 [`scripts/fishing_encounter_system.gd:262-336`](scripts/fishing_encounter_system.gd#L262)。
5. 单钩与每个串钩钩位分别累计 hazard；达到指数分布随机阈值后，才从有效鱼群候选中按事件率选一个候选。见 [`scripts/fishing_encounter_system.gd:383-415`](scripts/fishing_encounter_system.gd#L383)。因此“候选有效”和“这次随机中鱼成功”是两个步骤。
6. 单钩进入 `begin_boat_fishing_approach()`；浅水时先创建短暂的接近演出，动画结束后再次验证鱼群并确认 Hooked。串钩则先为对应钩位建立 pending/reservation，浅水时执行该钩位的接近演出，完成后确认挂钩。见 [`scripts/boat_fishing_casting_system.gd:1093-1144`](scripts/boat_fishing_casting_system.gd#L1093)、[`scripts/boat_fishing_casting_system.gd:1149-1198`](scripts/boat_fishing_casting_system.gd#L1149)、[`scripts/fishing_encounter_system.gd:545-595`](scripts/fishing_encounter_system.gd#L545)。

## 2. 鲱鱼水深数据的实际含义

### 海床深度和鱼游深度是两个字段

`FishSpeciesProfile.minimum_depth_m / maximum_depth_m / preferred_depth_*` 的文档明确注明是 **LAT 基准下的海床图深**，不是鱼离水面的游泳深度。`suitability_for_depth()` 用这些值决定该海床位置是否适合生成该鱼种鱼群。见 [`scripts/fish_species_profile.gd:18-23`](scripts/fish_species_profile.gd#L18) 与 [`scripts/fish_species_profile.gd:102-113`](scripts/fish_species_profile.gd#L102)。

因此，鲱鱼 `minimum_depth_m = 8` 表示海床生境至少约 8 米深；它不是“鲱鱼必须在水下 8 米才能中鱼”。鲱鱼配置的海床范围为 8–53 米，偏好海床深度为 17–43 米。见 [`resources/fish_species/herring.tres:16-19`](resources/fish_species/herring.tres#L16)。

### 0.7–2.5 米和 8–24 米怎么用

鲱鱼配置了表层活动深度 `Vector2(0.7, 2.5)`、深层活动深度 `Vector2(8.0, 24.0)`、表层时间占比 0.40、表层停留 25–90 秒、垂直活动速度 0.75 m/s。见 [`resources/fish_species/herring.tres:27-36`](resources/fish_species/herring.tres#L27)。

这两个 Vector2 **不是中鱼时直接检查的连续深度区间**。Authority 初始化某个鱼群时，分别从表层和深层 Vector2 中抽取单个深度目标；按 `surface_activity_time_share` 决定初始化在 `near_surface` 还是 `deep`。见 [`scripts/fish_local_authority.gd:453-468`](scripts/fish_local_authority.gd#L453) 与 [`scripts/fish_local_authority.gd:507-512`](scripts/fish_local_authority.gd#L507)。鲱鱼后续在表层、下降、深层、上升之间循环，更新 `FishSchoolState.activity_depth_m`；深层停留时间按表层时间和 40% 占比换算，并带确定性变化。见 [`scripts/fish_local_authority.gd:471-504`](scripts/fish_local_authority.gd#L471) 和 [`scripts/fish_local_authority.gd:515-526`](scripts/fish_local_authority.gd#L515)。

中鱼评估读取的是 Authority 快照里的**当前单个 `activity_depth_m`**，不是目标范围、状态名或两个端点。`FishSchoolState.depth_m` 是海床深度，`activity_depth_m` 是鱼群游深字段，两者会分别序列化。见 [`scripts/fish_school_state.gd:14-19`](scripts/fish_school_state.gd#L14) 与 [`scripts/fish_school_state.gd:32-49`](scripts/fish_school_state.gd#L32)。

### Authority 与可见鱼的深度不同步风险

Authority 将 `delta` 累积到 8 秒后，以 `step = 8.0` 推进鱼群；鱼群数量多时还会分帧处理批次。见 [`scripts/fish_local_authority.gd:64-77`](scripts/fish_local_authority.gd#L64) 与 [`scripts/fish_local_authority.gd:13-14`](scripts/fish_local_authority.gd#L13)。活动深度一次最多移动 `activity_vertical_speed_mps × step`；鲱鱼即最多约 `0.75 × 8 = 6 m`。见 [`scripts/fish_local_authority.gd:471-492`](scripts/fish_local_authority.gd#L471)。

渲染鱼个体则在每帧以 `activity_vertical_speed_mps × frame_delta` 向 Authority 的新深度移动。见 [`scripts/fish_school_renderer.gd:1268-1279`](scripts/fish_school_renderer.gd#L1268)。鱼群可视化状态还允许活动深度约到 6 米附近，并有 0.35 米显示迟滞；可见鱼不等于鱼必然位于配置表的 0.7–2.5 米表层目标内。见 [`scripts/fish_school_renderer.gd:691-705`](scripts/fish_school_renderer.gd#L691) 与 [`scripts/fish_species_profile.gd:74-76`](scripts/fish_species_profile.gd#L74)。

这里存在结构性的时序差异：鱼模型平滑追逐深度，但中鱼判定读取 Authority 当前值。例：Authority 从浅层跨步更新到较深值后，模型仍可逐帧下沉；在这段时间里，近水面的钩可能对 Authority 深度得到零权重。静态代码能够确认这种不同步可能，不能仅凭代码断定用户某次未中鱼一定由它造成。

另外，渲染器会平滑/预测鱼群的水平可视位置；鱼钩候选查询使用 Authority 原始 `world_position`。表层个体还会围绕鱼群锚点游动。见 [`scripts/fish_school_renderer.gd:781-845`](scripts/fish_school_renderer.gd#L781) 与 [`scripts/fish_school_renderer.gd:953-965`](scripts/fish_school_renderer.gd#L953)。因此玩家看到的鱼个体位置和判定使用的鱼群中心也不完全相同。

## 3. 鱼饵和五个钩位的真实水深

- 海面：`_sample_water(position)` 调用现有 `WaveSampler.sample_physics_surface(position, effective_wave_time)`，即动态物理海面；没有在船钓中另建海面数据源。见 [`scripts/boat_fishing_casting_system.gd:2199-2204`](scripts/boat_fishing_casting_system.gd#L2199)。
- 单钩：钩位列表直接返回 `_bait_world`。落水后实际深度为 `max(0, sampled_surface_height - _bait_world.y)`。见 [`scripts/boat_fishing_casting_system.gd:645-650`](scripts/boat_fishing_casting_system.gd#L645) 与 [`scripts/boat_fishing_casting_system.gd:2207-2211`](scripts/boat_fishing_casting_system.gd#L2207)。
- 串钩：铅坠位置是 `_bait_world`；各钩位由当前整体向上方向和 `bottom_leader_length_m + (hook_count - index - 1) × hook_spacing_m` 推导。数组次序为 Hook 1（靠竿）到 Hook 5（靠坠）。每个空钩都单独对该世界坐标采样动态海面并计算深度。见 [`scripts/boat_fishing_casting_system.gd:653-664`](scripts/boat_fishing_casting_system.gd#L653) 与 [`scripts/boat_fishing_casting_system.gd:1060-1073`](scripts/boat_fishing_casting_system.gd#L1060)。
- 放线长度：没有作为真实深度代替值；深度来自钩位世界 Y 和动态水面高度。线长可能通过现有运动约束间接改变 `_bait_world`，但候选评估本身不把 `line_length_m` 当成深度。
- 缓存：上述深度路径每次评估都重新调用波面采样；没有看到船钓层的水深缓存。鱼群 `activity_depth_m` 则来自最近一次 Authority 更新快照，并不会随每次钩位查询连续推进。

## 4. 实际水层匹配公式与数值

`evaluate_boat_fishing_candidates()` 使用：

```text
activity_depth = max(0, school.activity_depth_m)
vertical_delta = abs(activity_depth - max(0, hook_depth_m))
vertical_tolerance = clamp(school_activity_radius_m * 0.7, 1.2, 3.0)
depth_weight = 1 - smoothstep(vertical_tolerance * 0.35,
                              vertical_tolerance,
                              vertical_delta)
```

代码位置：[`scripts/fishing_encounter_system.gd:277-283`](scripts/fishing_encounter_system.gd#L277)。这是**钩位到当前单个代表深度的距离**，不是钩位到活动区间最近边界的距离。深度区间宽度本身不参与公式。

鲱鱼 `school_activity_radius_m` 默认 4.2 米，因此 `tolerance = clamp(4.2 × 0.7, 1.2, 3.0) = 2.94 m`，衰减从 `1.029 m` 的垂直差开始，到 `2.94 m` 降为 0。见 [`scripts/fish_species_profile.gd:67`](scripts/fish_species_profile.gd#L67)。区间全体不是最高权重：只有和当前代表深度差不超过 1.029 米时才是 1。

由于 Authority 当前深度会在表层范围抽成一个标量，无法只凭配置范围对某次运行给出唯一权重。下表按两个角度计算：中间列假设当前 Authority 值恰为表层范围中点 `D=1.6 m`；最后一列是 Authority 值确实处于 `[0.7,2.5]` 时可能的权重范围。真实切换中的 Authority 值可在此范围之外，需代入实际值重新算。

| 鱼饵深度 | `D=1.6m` 的实际权重 | 若当前 `D∈[0.7,2.5]`，权重范围 |
|---:|---:|---:|
| 0.5 m | 0.996 | 0.488–1.000 |
| 1.0 m | 1.000 | 0.848–1.000 |
| 2.0 m | 1.000 | 0.945–1.000 |
| 2.5 m | 1.000 | 0.643–1.000 |
| 3.5 m | 0.566 | 0.015–1.000 |
| 5.0 m | 0.000 | 0.000–0.135 |
| 8.0 m | 0.000 | 0.000–0.000 |

例：`D=1.6m`、鱼饵 3.5m，差 1.9m，权重约 0.566；鱼饵 5m，差 3.4m，权重为 0。鱼饵处于某个“配置活动范围”里并不自动得到满权重；而且切换过程中的 `activity_depth_m` 可是中间深度。

## 5. 中鱼检查周期、运动距离与漏采分析

### 周期与帧率

`boat_fishing_sampling_interval_real_seconds` 默认 0.5 秒，导出范围 0.2–1.5 秒。仓库场景/资源中未找到覆盖这个运行时默认值的序列化设置。每帧先累加 `_process` 的 `delta`；达到间隔后做**一次**检查，使用这段时间累计的世界游戏秒数计算 hazard。代码没有 `while` 补做多个历史采样。见 [`scripts/boat_fishing_casting_system.gd:80-81`](scripts/boat_fishing_casting_system.gd#L80) 与 [`scripts/boat_fishing_casting_system.gd:1042-1058`](scripts/boat_fishing_casting_system.gd#L1042)。

因此，在稳定帧率下检查频率基本不随 FPS 增加；随机 hazard 也按游戏时间累计，而不是每帧掷一次随机数。固定中鱼率的等价单区间概率为 `p = 1 - exp(-λ × Δt_game / 3600)`，代码的 hazard 阈值由 `-ln(U)` 生成。见 [`scripts/fishing_encounter_system.gd:383-415`](scripts/fishing_encounter_system.gd#L383) 与 [`scripts/fishing_encounter_system.gd:866-869`](scripts/fishing_encounter_system.gd#L866)。

位置方面只使用当前采样点；没有上一次亮片或钩位位置用于轨迹检测。游戏时间增量与位置采样间隔不同：采样计时使用 `_process delta`，hazard 时间来自世界游戏时钟。若游戏时间倍率变化，时间概率随游戏时钟变化；FPS 不会简单地多掷随机数。

### 指定速度下两次检查的位移

按默认 0.5 秒计算：

| 鱼饵相对水体速度 | 两次位置采样间移动距离 |
|---:|---:|
| 0.5 m/s | 0.25 m |
| 1.5 m/s | 0.75 m |
| 3.0 m/s | 1.50 m |

所以这些速度下，稳定帧率时一次采样通常不会跨过完整的 10 米水平权重分段；水平距离的几何漏采不是高概率主因。但算法确实有端点采样误差：如果两个端点的水平/水层权重都低，而中间瞬间更高，系统不会看到中间高值；若检查前发生较长帧停顿，也只评估停顿后的端点。随着鱼群运动、鱼饵垂直变化或水层匹配边缘，风险也会增加。

### 三种不能混为一谈的失败

1. **漏掉候选鱼群：** 查询只在当前位置调用 `get_schools_near(position, 50m)`。Authority 接口只返回当前点周围的鱼群中心；它没有检查采样区间扫过的区域。见 [`scripts/fishing_encounter_system.gd:268`](scripts/fishing_encounter_system.gd#L268) 和 [`scripts/fish_local_authority.gd:93-109`](scripts/fish_local_authority.gd#L93)。
2. **候选存在但没采到高权重位置：** 有鱼群进入候选后，水平/深度权重仍按当前端点算，并把该端点总率乘以整个累计游戏时间。端点在低权重处会漏掉中段机会；反过来，端点刚进入高权重处也可能把过往整段时间都按高率计入。
3. **概率正常但随机没有中鱼：** 即便该采样点候选有效、权重大于零，hazard 也可能尚未越过随机阈值。这是概率模型的正常结果，不是空间查询漏掉。

另一个实现细节：当某次端点没有有效候选时，hazard 函数直接返回，已累计的部分 hazard 不清零；它只是不为这段零率时间继续增加。故短暂走出鱼群区域不会抹掉之前累积概率，但未采到的中间高率也不会补进来。

## 6. 50 米水平距离判定真实状态

统一曲线已在船钓单钩和串钩共用的评估函数中实现。候选查询半径也是 50 米；`FishLocalAuthority.get_schools_near()` 用 XZ 平面距离精确过滤，没有额外的 5.4 米或 28 米船钓前置半径。28 米 `encounter_radius_m` 属于拖钓参数，不参与这里的船钓查询。见 [`scripts/fishing_encounter_system.gd:15`](scripts/fishing_encounter_system.gd#L15)、[`scripts/fishing_encounter_system.gd:268`](scripts/fishing_encounter_system.gd#L268)、[`scripts/fishing_encounter_system.gd:355-367`](scripts/fishing_encounter_system.gd#L355) 与 [`scripts/fish_local_authority.gd:93-109`](scripts/fish_local_authority.gd#L93)。

| 水平距离 | 实际权重 |
|---:|---:|
| 5 m | 1.000 |
| 15 m | 0.925 |
| 25 m | 0.725 |
| 35 m | 0.450 |
| 45 m | 0.150 |
| 50 m | 0.000 |
| 55 m | 0.000（已被 50m 查询排除） |

距离相对 **Authority 鱼群中心** 和钩位/亮片的 XZ 坐标计算。不会扩展到鱼群边缘，也不把最近一个可见鱼个体当中心；鱼群活动半径没有加入水平权重，只用于垂直容差。

单钩、串钩调用同一水平曲线，但基础事件率和动作权重独立：单钩默认 1.2 次/游戏小时基准，串钩每个钩位默认 0.42 次/游戏小时基准；两者再乘鱼种 tendency、人口权重、水平、深度和动作权重。见 [`scripts/fishing_encounter_system.gd:37-45`](scripts/fishing_encounter_system.gd#L37) 与 [`scripts/fishing_encounter_system.gd:270-304`](scripts/fishing_encounter_system.gd#L270)。

Sabiki 的五个空钩各自以 `hook_index` 保存 hazard 与随机阈值；每个钩位的候选率按该钩实际位置/深度算，没有把一次钩中结果直接乘五。有效鱼数还要扣掉该鱼群已预留数量。见 [`scripts/fishing_encounter_system.gd:286-288`](scripts/fishing_encounter_system.gd#L286) 与 [`scripts/fishing_encounter_system.gd:399-415`](scripts/fishing_encounter_system.gd#L399)。五个钩若都处于高权重区，整体出现任意一次事件的机会自然会高于单钩，但这来自独立钩位的 hazard，不是额外乘以五的单次 RNG。

这也说明“经过鱼群”仍可能很久不咬。以配置未另设的鲱鱼 `relative_bite_tendency = 1`、初始种群至少 35（`population_weight` 因而封顶为 3）、距离和深度权重均为 1 估算：单钩最高为 `1.2 × 3 × 1 × action_weight`，即约 1.98–3.6 次/游戏小时；串钩每个完全匹配的空钩约 1.008–1.26 次/游戏小时。即使理想水层与近距离下，短时间通过只代表获得一段很短的概率累计，不是一次必中的区域触发。若只有 10 个游戏秒的理想暴露，单钩概率约 0.55%–1.00%；串钩五钩全都有效且资源足够时合计约 1.4%–1.7%。实际游戏时间倍率需运行时确认，距离或水层权重降低还会继续压低这些数值。

## 7. 鱼饵运动权重

自然判定先计算 `relative_velocity = bait_velocity - boat_velocity × 0.78`，然后只把速度模长传给候选评估。见 [`scripts/boat_fishing_casting_system.gd:1059-1071`](scripts/boat_fishing_casting_system.gd#L1059)。鱼饵运动由等待状态物理更新：包括下沉、线长约束、收放线、竿尖/船的作用；见 [`scripts/boat_fishing_casting_system.gd:1920-1945`](scripts/boat_fishing_casting_system.gd#L1920)。

没有独立的“收线、放线、抽竿、停顿”概率状态开关；这些操作只有在实际改变鱼饵相对运动时才间接影响权重。匀速船行时鱼饵水平速度会跟随 `0.78 × boat_velocity`，随后再减去同一项，所以稳态的船速本身不等价于同等拟饵动作加成。

| 相对速度 | 单钩权重（0.55→1，参考 2.5m/s） | 串钩权重（0.80→1，参考 2.5m/s） |
|---:|---:|---:|
| 0 m/s | 0.55 | 0.80 |
| 0.5 m/s | 0.64 | 0.84 |
| 1.5 m/s | 0.82 | 0.92 |
| ≥2.5 m/s | 1.00 | 1.00 |

公式为 `lerp(min_weight, max_weight, clamp(relative_speed / 2.5, 0, 1))`，见 [`scripts/fishing_encounter_system.gd:339-352`](scripts/fishing_encounter_system.gd#L339)。单钩收线穿过鱼群时，只要相对速度实际测得非零，就会有温和动作增益；它不会因“路线穿过鱼群”额外加成，也不保证咬钩。串钩所有空钩共享坠子速度，不逐钩计算各钩随姿态变化的速度。

## 8. 浅水接近动画和真实判定的关系

浅水阈值默认 6 米，依据的是亮片或对应钩位的实际水深。见 [`scripts/boat_fishing_casting_system.gd:80-81`](scripts/boat_fishing_casting_system.gd#L80) 与 [`scripts/boat_fishing_casting_system.gd:2498-2500`](scripts/boat_fishing_casting_system.gd#L2498)。

它是**中鱼随机判定成功后的演出**，不是鱼的追逐 AI，也不参与中鱼概率。单钩先从 Authority 候选结果建立 pending，再在浅水时从鱼种 `model_path` 临时实例化一个可视化鱼；起点距亮片约 2.8–5.5 米，并取候选鱼群方向/深度，演出结束后才 `confirm_boat_fishing_bite()`。见 [`scripts/boat_fishing_casting_system.gd:1339-1414`](scripts/boat_fishing_casting_system.gd#L1339) 与 [`scripts/boat_fishing_casting_system.gd:1611-1629`](scripts/boat_fishing_casting_system.gd#L1611)。因此它不是复用鱼群中某一条真实可见个体；视觉鱼实体是在事件被抽中后创建的代理。

单钩演出时长为 `clamp(start_distance / species_average_speed, 1.0, 4.5)` 秒，再用 smoothstep 插值移动；鲱鱼配置的平均游速是 `(0.35 + 0.9)/2 = 0.625m/s`。因为距离被限制在近钩位置且时长有上限，演出速度不保证等于鱼种配置游速。串钩也用独立演出时长 `clamp(distance / species_average_speed, 0.8, 3.6)`，并沿钩位移动；鱼体同样是临时模型代理。见 [`scripts/boat_fishing_casting_system.gd:1360-1383`](scripts/boat_fishing_casting_system.gd#L1360) 与 [`scripts/boat_fishing_casting_system.gd:1113-1141`](scripts/boat_fishing_casting_system.gd#L1113)。自然鱼群中心若离钩较远，单钩演出仍会把代理起点距离钩限制在 2.8–5.5 米范围，取大致朝向而不会让真实 Authority 中的鱼从几十米外游过来。

串钩对各钩位分别执行相似流程：浅水时临时鱼游向该钩，抵达后确认挂钩；深水时可跳过接近演出直接确认。见 [`scripts/boat_fishing_casting_system.gd:1093-1144`](scripts/boat_fishing_casting_system.gd#L1093) 与 [`scripts/boat_fishing_casting_system.gd:1149-1198`](scripts/boat_fishing_casting_system.gd#L1149)。它和单钩属于相似但分别实现的代码路径，并非一个共享动画函数。

**结论：** 画面里看见鱼游向亮片，只表示中鱼概率已经先成功；鱼的演出运动不会反向触发中鱼，也不会更新 Authority 数量或水层候选。

## 9. A、B、C 轨迹方案比较

### A：保持当前定时点采样

- **优点：** 零新增轨迹状态；CPU 最低；候选资源预留、随机 hazard 和结算边界不变；在静止、慢速等待时语义简单。
- **缺点：** 端点权重代表整个采样时间，不是区间平均；高移动、长帧停顿、深度快速变化时可能漏掉中间的候选或高权重，也可能把端点高权重错误用于前一段时间。
- **对当前场景：** 在 0.5–3m/s、0.5 秒采样、水平 10 米权重分段下，正常运行时空间间距仅 0.25–1.5 米。它基本能支持慢速“经过”鱼群，不太像是唯一或主要障碍；水层权重为零、视觉/Authority 深度不同步和低自然事件率都会让经过仍然不咬。
- **性能：** 当前开销；单钩每周期一次 Authority 半径查询，串钩最多五次。

### B：两次检测间的运动轨迹

- **计算思路：** 对每个鱼群中心与钩位 XZ 轨迹线段求最近参数 `t* = clamp(dot(C-A, B-A)/|B-A|², 0, 1)`，再用 `A.lerp(B,t)` 得该点水平距离。若只用 `t*` 的最大权重代替整段概率，会错误地把一次短暂擦边当成整个周期都在高权重区。正确实现仍须沿时间积分 `λ(t)=Σ学校 λ_0 × population × horizontal_weight(t) × depth_weight(t) × action_weight(t)`，再用 `1-exp(-∫λdt/3600)` 计算整段事件概率。
- **优点：** 能直接识别端点之外的穿越；线性移动、鱼群中心静止时，几何路径清晰；可一次取得路径周围候选学校。
- **缺点：** 要处理水平距离和随时间变化的深度；水面高度需在对应插值时间采样；需处理 cast 入水、切换活动、收线出水、瞬移/重置等不连续段；候选鱼群在路径中可能变化；多钩需要按钩位各自积分，并在同一周期内串行预留资源。单纯最近点会高估机会。
- **性能：** 一次路径候选查询后，按“学校数 × 路径积分采样数 × 空钩数”增加评估；候选学校缓存和较低积分点数可控，但代码改动比 C 大。

### C：保留低频检查，按移动量自适应少量采样

- **计算思路：** 仍每 0.5 秒启动一次区间评估；保存上一采样的单钩/各钩位置与深度。仅当水平位移或水深变化超过选定空间步长时，把线段切成有限个子段，在子段中点/端点计算对应的候选率，以每段所占游戏时间积分 hazard。不要在每个子点各自重置/重新掷随机数，而应对整段累计一次概率并最多产生一次事件。
- **何时加点：** 位移/深度变化相对于水平权重过渡尺度或垂直容差足够大时增加；稳定静止或极慢移动保持一个样点。采样上限应固定，避免长帧停顿造成无界工作量。
- **优点：** 保留现有低频调度和 Authority API，适合当前代码结构；正常速度几乎没有额外成本；对高速度、帧卡顿、上下抽竿轨迹更稳健；不要求全套解析线段求解。
- **缺点：** 要新增上一位置/深度和连续段重置规则；若只调用现有端点评估再多掷几次随机数，会造成概率随采样点数增加，必须改为区间 hazard 积分。仍需决定鱼群 Authority 深度在本周期内是否视为常数。
- **串钩成本：** 只对空钩做自适应采样；最多 `hook_count` 条短路径。可在一个采样周期共享路径附近的候选学校列表，再计算各钩自己的距离/深度/概率；同一鱼群各钩 reservation 仍需逐次检查。

## 10. 建议和待确认事项

### 建议

按 A/B/C 选，建议 **C：低频检查 + 有上限的自适应轨迹积分**。它与当前“候选评估 → 连续时间 hazard → reservation”结构最接近，能够以有限额外查询改善大位移、垂直抽动和帧停顿时的路径漏采。

但针对当前“看见表层鲱鱼、亮片从后方穿过却无咬口”的具体反馈，我不建议把单纯加密鱼饵采样当作首要修复。默认轨迹采样已是 0.5 秒，给出的 3m/s 也只移动 1.5 米；静态代码更突出的疑点是：**Authority 单点活动深度按 8 秒步进更新，而画面鱼逐帧追随；中鱼公式又只匹配 Authority 单点深度。** 下一步应首先记录同一时刻的 school ID/state/activity_depth、可见鱼平均深度、每个钩深、水平距离、`depth_weight`、候选率和 rejection reason。若记录证实两者错位，先统一判定与渲染使用的时间一致深度；随后再上 C。否则，仅提高轨迹采样密度仍会对同一个不匹配的深度反复算出零权重。

### 需要进一步确认

1. 用户遇到问题的那个鱼群当时 `surface_activity_state` 和 Authority `activity_depth_m` 是多少？可见鱼平均深度是多少？两者是否偏差超过 1–3 米？静态代码不能给出该运行时值。
2. 亮片通过区域时的真实动态水深与相对水体速度是多少？HUD 的放线长度不能回答这个问题。
3. 当前游戏时钟倍率是多少？采样间隔使用进程 `delta`，概率累计使用世界游戏时间，因此需要该值才能把每小时事件率换算为玩家感知的现实秒数。
4. 渲染可见边界附近的鱼群，是否应继续作为可钓候选？当前渲染阈值和捕获水层权重是两套独立规则。
5. Authority 的 8 秒更新间隔和逐帧鱼体深度平滑是否是有意的生态/性能折衷？改变其一会影响全局鱼群表现，宜先通过上述数据确认。

## 对最终场景的直接回答

玩家把亮片抛到鲱鱼群后方并收线时，程序每半秒在亮片当前点查 50 米内的 Authority 鱼群；对每个候选分别计算到鱼群中心的水平权重、亮片深度到当前群体单点 `activity_depth_m` 的权重，再乘鲱鱼兼容性、可用数量和按相对运动速度计算的动作权重，最后按游戏时间的随机 hazard 决定是否中鱼。它没有判断完整的“鱼饵从后方穿过鱼群”轨迹，也不会因为穿越本身保证咬口。

当前最主要的限制不是 0.5 秒内 1.5 米的普通水平采样距离，而是判定采用鱼群中心的单点水深、鱼群深度 Authority 的 8 秒步进与可见个体的逐帧平滑存在时序差异，以及每小时事件率本身仍是概率而非保证。**最小且结构合适的轨迹改动是方案 C 的有限自适应积分；要显著改善这类表层鱼体验，还应先让中鱼使用的鱼群深度与画面鱼的当前深度一致，并用运行时数据验证。**
