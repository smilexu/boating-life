# P6.4.1 船钓搏鱼系统架构审查与实施规划

审查日期：2026-11-02  
范围：静态代码审查；仅新增本报告，未修改正式游戏代码、资源、输入映射或测试。

本文用以下标记区分证据和设计：

- **已确认**：由当前代码、场景或资源直接确认。
- **建议**：下一阶段可以采用的实现方案，不代表已经实现。
- **待验证**：仅凭静态检查无法确认的运行时表现或场景细节。

## 结论摘要

当前船钓已经有抛投、落水运动、单钩/五钩位置、中鱼候选、预留、浅水接近演出、手动空线收放和收获结算。不过中鱼后仍然依赖自动搏鱼流程：单钩把 `FishingRodSystem` 的预制 presentation 时间线当作船钓收鱼控制；串钩的主动收获也会进入自动批量收线。当前没有按鱼种、体型模拟的拉力/体力，没有玩家泄力值，也没有按主线承载力计算的张力或断线模型。

最重要的架构边界是：**保留 `FishingEncounterSystem` 作为候选鱼与 Authority 资源/结算的唯一来源；新增船钓专用搏鱼状态与求解逻辑；保留 `BoatFishingCastingSystem` 对船钓钩组和唯一线长字段的权威写入；不要把拖钓 `FishingRodSystem` 的自动时间线借来控制新搏鱼。** 鱼竿弯曲、竿尖抽动只读张力输出，不能反馈到求解。

另外，当前拖钓 `FishingRodSystem` 会订阅共享的 `fish_hooked`/`catch_succeeded` 事件。船钓直接调用共享 encounter 生命周期时，它也会启动自己的真实渔获 presentation。即使船钓跳过 fight-camera，仍可能让拖钓竿模型和 presentation 状态响应船钓事件。该边界应在集成阶段明确隔离，否则有复现先前“船钓测试看起来像拖钓”的回归风险。

## 1. 现有架构和关键文件

| 模块 | 当前职责与证据 |
|---|---|
| `scenes/Boat.tscn:104-112` | 场景中同时挂有 `FishingRodSystem` 和 `BoatFishingCastingSystem`。前者有拖钓竿架、拖钓 presentation/audio；后者负责手持船钓竿。 |
| `scripts/boat_fishing_casting_system.gd:12, 54-81` | 船钓状态枚举、视角/水面/海底/音效依赖、手动收线速度、放线速度和 0.5 秒中鱼采样配置。状态含 `READY`、`CHARGING`、`CASTING`、`WAITING`、`SABIKI_HOOKED_WAITING`、`RETRIEVING`、`BITE_APPROACH`、`FIGHTING`、`CATCH_PRESENTATION`。 |
| `scripts/boat_fishing_casting_system.gd:993-1041` | 单一 `_process` 分派船钓状态，等待期间更新钓组、鱼类接近、自然中鱼；`FIGHTING` 调用自动流程；最后统一更新鱼线、卷线器、声音与鱼视觉。 |
| `scripts/boat_fishing_casting_system.gd:699-718` | `get_hook_world_positions()` 返回亮片位置或 Sabiki 五个实际钩位；钩位顺序 Hook 1 靠竿、Hook 5 靠铅坠。 |
| `scripts/fishing_encounter_system.gd:266-345, 416-448` | 单钩和 Sabiki 调用同一鱼群候选查询；用钩/饵世界位置、实际水深、50 m 水平模型、兼容性、动作、鱼群有效活动深度及独立 hazard。候选/概率属于 Authority 层，船钓搏鱼不应重写。 |
| `scripts/fishing_pending_catch.gd:1-34` | 待处理捕获记录含 catch/species/school/rig/hook/body length/debug 等身份数据，没有搏鱼拉力、体力或个体实时位置。 |
| `scripts/fishing_catch_result.gd:1-40` | 成功结果承载鱼种、尺寸、重量、批次、鱼群前后数量及 debug 标记；适合继续作为结算结果，不适合承载逐帧搏鱼状态。 |
| `scripts/fish_species_profile.gd:17-19, 31-70, 93-101` | 已有自然体长、鱼群移动速度、生态/垂直层、捕获方式、拟饵兼容和咬钩倾向；没有搏鱼力量、体力或爆发参数。 |
| `scripts/fishing_fight_profile.gd:1-75` 和 `resources/fishing/fight_profiles/*.tres` | 资源明确描述拖钓的竿负荷、固定挣扎脉冲、反向线速、表面动作和提鱼动作；其注释为 presentation 参数。它是预设时间演出，不是力/体力模型。不要改用该时间表充当船钓力学。 |
| `scripts/fishing_rod_system.gd:601-649, 705-741` | `FishingRodSystem` 接收共享 `fish_hooked`，播放 Hook Strike → struggle → 固定时长 progressive retrieval → surface landing，并调用 encounter 完成捕获。对 `boat_fishing` 只跳过自动切换摄像机，仍会启动自己的竿、鱼和线 presentation。 |
| `scripts/fishing_rod_rig.gd:72-89, 159-161, 833-879` | 拖钓竿负荷、竿尖回弹和线张力驱动的是模型/线条视觉；`set_line_tension()` 改变线条下垂，不是鱼线力学求解。 |
| `scripts/boat_hud.gd:764-776, 796-824` | HUD 持续按下“收线”按钮会调用船钓 `set_manual_reeling`；串钩有独立“收获钓组”按钮及挂鱼数量。当前没有泄力控制或读数。 |
| `scripts/fishing_debug_panel.gd:71-104, 289-305` | F3 Fishing 已有拖钓模拟、船钓测试鱼、指定/填满 Sabiki 钩位及自然中鱼诊断，面板可见时每 0.5 秒刷新。当前还没有真实张力、泄力、每条鱼的力量/体力或断线危险数据。 |

## 2. 当前状态流及需要替换的部分

### 2.1 抛投、等待和空钩收回

**已确认**：`BoatFishingCastingSystem` 的抛投为 `READY → CHARGING → CASTING → WAITING`。左键在 READY 蓄力、松开抛投；WAITING 时同一左键变成手动收线，F 键（`boat_fishing_pay_out`）主动放线；鼠标左键因此已具有状态相关用途（`project.godot:38-47`、`boat_fishing_casting_system.gd:952-990`）。

等待期间 `_line_paid_out_length_m` 是现有唯一的已放线长度字段，但实际收线/放线直接以固定速度改它；亮片/钩组的运动和几何距离随后与该长度协调，`_rod_tension` 是由线距超额产生的 0–1 视觉量，不是鱼力张力（`boat_fishing_casting_system.gd:2070-2148`）。鱼饵、线长、卷线器动画和线网格大多在同一个脚本中维护。

**建议**：中鱼前保持这套抛投/落水逻辑；中鱼后以同一条 canonical paid-out length 进入搏鱼求解器。求解器每个时间步只返回一份实际线速/长度增量，`BoatFishingCastingSystem` 只应用一次，再由它派生亮片、五钩、鱼线和绕线视觉位置。不要再在独立控制器里复制第二个 line length 或鱼钩位置字段。

### 2.2 单钩

**已确认**：自然候选通过 `evaluate_boat_fishing_candidates()`；中鱼候选会进入 `begin_boat_fishing_approach()`，`FishingPendingCatch` 在鱼靠近动画期间就已建立。水深小于 6 m 时，`_advance_bite_approach()` 把一个临时鱼模型从附近移动到亮片；接触后 `confirm_boat_fishing_bite()` 才进入 encounter 的 HOOKED 状态（`boat_fishing_casting_system.gd:1472-1585`、`fishing_encounter_system.gd:578-628`）。这条鱼是根据物种模型创建的临时视觉代理，不是鱼群渲染器中的某条 Authority 个体实体。

接触后当前船钓设为 `FIGHTING`，开启 `_automatic_control_owned`，然后 `_advance_auto_fight()` 读取 `FishingRodSystem.get_presentation_snapshot()` 的预设阶段、线距离和 backing-out 状态；按其阶段改写饵位置、线长、鱼模型位置，最后等待拖钓 presentation 的结算事件（`boat_fishing_casting_system.gd:1588-1687`）。因此现在并非玩家搏鱼：左键手动控制被锁，线长不是由实际鱼力与泄力求解。

**建议**：保留接近动画和“鱼接触钩子才确认”的事件边界；从 `FIGHTING` 起取消自动时间线所有权。玩家左键成为收线请求，松开只停止主动收线；鱼力可以在任何左键状态下触发出线。达到船边提鱼范围后才进入自动 `LANDING` 与结算。

### 2.3 五钩串钩

**已确认**：每钩 `status` 有 `empty / approaching / reserved / hooked`，每个钩位有其 `FishingPendingCatch` 和临时鱼模型。挂一条后状态为 `SABIKI_HOOKED_WAITING`，其余空钩继续接受自然判定。当前达到最大挂钩数时，`_advance_sabiki_hook_approaches()` 会立即调用 `request_sabiki_retrieval()`；玩家点 HUD“收获钓组”也会触发该函数（`boat_fishing_casting_system.gd:1111-1137, 1226-1330, 579-628`）。它锁定批次并进入共享 `FIGHTING`，再走自动收线。

**建议**：P6.4 取消“满钩自动收线”。第一条鱼及后续鱼都加入同一搏鱼会话，五钩状态继续附着到各自钩位；空钩持续参与自然判定，包括已挂鱼但仍在水中的搏鱼时段。只有玩家实际收回并且钩组到达提鱼范围，才冻结批次、停止新咬钩并自动提鱼/统一结算。不能因串钩鱼数多就添加固定断线概率。

### 2.4 当前自动收获和结束处理

单钩当前自动 timeline 到达 surface landing 后完成 Authority 结算，再进入 catch presentation；串钩 `begin_sabiki_batch_retrieval()` 将所有已确认 catch 设为一批，最终一次原子扣减并发出结果（`fishing_encounter_system.gd:518-535, 642-701, 704-785`）。空钩手动收回则另有约 0.72 秒的 `RETRIEVING` 动画，结束后直接回 READY（`boat_fishing_casting_system.gd:2176-2216`）。

新流程应保留“Authority 结算成功后才增加结果/播放一次成功事件”的顺序。空钩快速回收可保留；有鱼的回收必须以实际线速推进，不能用固定时长把线长清零。

## 3. Authority、预约和结算生命周期

**已确认**：

- 自然候选及 50 m/水层/动作概率由共享 `FishingEncounterSystem` 和 `FishResourceManager` 提供；不要复制鱼群或生成新 Authority 鱼。
- Sabiki 预留存在 `_sabiki_hook_catches`，候选计算用学校 population 减去同脚本中已预留数量；`confirm_sabiki_hook()` 再检查资源。正式鱼群数量不会在预留时递减。
- 单钩 `begin_boat_fishing_approach()` 检查学校仍存在且 population 大于零，并保留单个 `pending_catch`；population 只在 `complete_retrieval()` 时调用 `request_population_change(..., -1)` 递减。
- 批量完成通过 `request_population_changes()` 原子扣减所有自然鱼；debug fish 不提交 population mutation。
- 取消单钩会清掉 `pending_catch`；取消 Sabiki 会清空批次列表。未结算的鱼当前不会因取消而被 Authority 扣减。
- `FishingPendingCatch` 用 catch ID、school ID、hook index、body length 和 `debug_spawned` 关联真实捕获；结算依赖它们，不能在新搏鱼会话里重抽体型或重新创建 catch。

**集成风险**：Encounter 目前把拖钓状态、单个 `pending_catch` 和 Sabiki catches 放在同一对象中。Sabiki 在等待累积时 encounter 的主 `state` 仍可能是 IDLE，而 `start_trolling()` 对 `_sabiki_hook_catches` 没有显式检查（`fishing_encounter_system.gd:210-220`）。活动 UI 通常避免两活动并行，但仅靠这个入口状态检查不能证明代码层互斥。P6.4 应在现有 Encounter 上加入清晰的活动所有权/会话约束，而不是另建一套鱼群或库存权威。

**建议事件语义**：

1. 预留时继续使用现有 `FishingPendingCatch` 和 hook index；浅水时仍然先做接近，再确认 hook。
2. 搏鱼中自然鱼保持 reservation；Sabiki 每钩独立占用可用数量。debug fish 始终 `debug_spawned=true`。
3. 断主线或退出活动：取消这次 boat fishing pending/batch，释放本地预留/引用、删除视觉体、停止循环音效；不调用人口扣减、渔获结果或成功音。断线后的“鱼获丢失”表示本次不入账；目前系统按未结算不扣 population 的语义最自然。
4. 鱼进入提鱼点后再走船钓专用的 landing/settlement API；单鱼调用一次、串钩整批一次。复用现有 `FishingCatchResult` 和 Authority 的原子人口变化，不创建第二库存。
5. 当前通用 `fish_hooked` / `retrieval_started` / `catch_succeeded` 会被拖钓 `FishingRodSystem` 订阅。建议新增 boat-specific lifecycle signal/API，或明确让拖钓消费者拒绝 `fishing_method == "boat_fishing"`；否则船钓事件会再次启动拖钓竿的预设动画。共享只限资源变更与结果数据，不共享搏鱼时间线。

## 4. 鱼、线长、鱼钩和船体空间

### 4.1 单一线长与张力

**已确认**：`_line_paid_out_length_m` 是船钓放出长度，`actual_line_length_m` 快照还显示竿尖到线连接点的几何距离；两者是“放线量”和“空间直线距离”两个不同量（`boat_fishing_casting_system.gd:853-905`）。中鱼中自动流程会按目标进度直接生成 `_bait_world`，随后重新计算线距离，并不由绳索求解器反推（`1639-1653`）。当前 `_rod_tension` 是视觉归一化值。

**建议接口**：一个船钓搏鱼会话输入 `dt_real`, rig/line config, current paid-out length, actual line/rod/hook world positions, fish participants, `reel_pressed`, `drag_setting`；输出只读 `FightFrame`：`tension_n`, `tension_ratio`, `line_rate_mps`（正值放线、负值收线）、`reel_in_rate_mps`, `line_out_rate_mps`, `drag_paying_out`, `break_danger_seconds`, `snapped`。每个时间步只在一个位置把 `line_rate * dt` 应用到 `_line_paid_out_length_m`，随后从该线长和钓组几何更新鱼饵/钩位。几何需求距离和 slack 作为派生量，不另存为第二个“实际线长”。

求解器不直接改 mesh、鱼竿角度或音效；视图脚本读 `FightFrame`，不能写回张力、线速或 fish force。真实长度下限/上限只由现有放线物理和 rig/线配置约束，卷线器绕线厚度仍是视觉输出。

### 4.2 鱼力量和体力

当前 `FishSpeciesProfile` 有自然长度范围和移动速度，但没有力量属性；现有 `FishingFightProfile` 是拖钓显示参数。因此建议单独建 boat-fishing 物种搏鱼配置（例如 `BoatFishingFightProfile`），不要复用拖钓 `FishingFightProfile` 的固定时间点脉冲。

每条鱼的运行时参与者数据建议包含：`catch_id`, `hook_index`, `species_id`, `body_length_m`, `stamina_ratio`, `burst_phase/time`, `swim_direction`, `world_position`, `debug_spawned`。它从待处理捕获记录初始化，只在当前会话存在，不写入鱼群人口持久化。

统一用牛顿（N）作为游戏标定力单位；在船钓线/钓组资源中提供主线断裂载荷 `F_break`，鱼力配置与此单位对齐。体型用有界的长度比例缩放，例如 `size_factor = clamp((length/reference_length)^exponent, min, max)`；物种配置给 `base_pull_N`, `burst_multiplier/duration`, `stamina_drain`, `recovery_rate` 和挣扎间隔。每条鱼的拉力为基础力 × 体型 × 体力系数，再乘当前 burst 系数。体力按真实 `dt` 消耗和恢复，体力减少会削弱持续挣扎，但不阻止玩家收获。

Sabiki 每条鱼独立更新；汇总沿主线方向的有效分力后用均方根合成：`F_eff = sqrt(sum(F_i_parallel^2))`。这样同向挣扎仍提高负荷，侧向/不同步挣扎不会像直接相加峰值一样线性爆涨，也不会退化成只取最强一条。实际参与分力需按支线/鱼的拉力方向投影；模型不求解真实绳索和支线弹性。

### 4.3 泄力、张力和断线危险

当前项目没有主线断裂承载力或 drag setting 字段；`BoatFishingRigProfile` 只有钩数、间距、下沉和兼容性（`scripts/boat_fishing_rig_profile.gd:6-21`）。需要先确定一个全船钓统一的承载力标定，再让配置记录断裂载荷和允许泄力区间。泄力设置 `d∈[0,1]` 连续变化成阈值 `F_drag = lerp(F_drag_min, F_drag_max, d)`；它只决定被动出线抵抗，不会把放线当成玩家主动操作。

推荐简单连续模型：

- 鱼的有效拉力低于泄力阈值时，未按左键就保持当前线长；按左键时收线速度随剩余负荷余量平滑下降。
- 鱼力超过泄力阈值时，产生正的 line-out rate；即使按住左键，过强拉力也会压制收线，越过阈值后可以反向出线。
- 实时张力稳态由鱼负荷与 drag 阈值决定；快速冲刺、拖动起步和收线抢力通过短时峰值项超过稳态阈值，但峰值应受上限和短响应时间限制。
- 在 drag 阈值附近使用短低通/滞回和小 deadband，避免出线/收线每帧翻转。断线计算使用张力峰值，视觉弯曲使用平滑后的张力。

断线危险用连续秒数积分，初始区段按用户给出的阈值做可配置曲线：`T/F_break < 0.70` 危险时间快速回落/清零；`0.70–0.85` 只提示视觉高负荷或极低累积；`0.85–1.0` 缓慢累积；`1.0–1.2` 快速累积；`>1.2` 使用短暂严重超载宽限后快速断线。每个区间按真实 `dt` 积分，与 FPS 无关；回到安全带后快速恢复危险计时，不能留下跨冲刺的永久疲劳。用户建议阈值应先作为调参起点，不得当成已验证平衡值。

### 4.4 鱼主动游动、被动收线与船边安全

**已确认**：当前自然鱼群渲染个体不是可操作的实体鱼。船钓单钩和 Sabiki 会生成临时模型代理；自动收鱼阶段将代理跟随钩位/亮片。现有鱼线显示的 `get_hull_clearance_line_route()` 只根据 hull-local `walkable_polygon_xz` 给松弛线生成抬高路径；代码注释明确它只改变可见线路，不改饵位置、线长和张力（`boat_fishing_casting_system.gd:2475-2521, 2720-2795`）。这不是鱼碰撞或主动游动约束。

**建议**：逻辑鱼位置从钩位和搏鱼状态产生；鱼主动运动方向每帧/每个 fight step 相对船体计算。设从最近船体水线点指向鱼的水平向量为外向轴，将主动游动方向中朝船体的内向分量投影去掉，余下只允许外游、侧游或向下/向上变化。收线造成的鱼钩/支线位移作为**被动拖曳**单独应用，允许被玩家拉向船，不受主动游动约束。不要用世界固定朝向或船头方向判断鱼是否靠船。

达到船边安全区后，自动沿船外侧到可提鱼点，再做简化 lift 与结算；鱼模型不得穿过船体。现有 `OnboardActivityProfile.walkable_polygon_xz` 是甲板可行走区，不是水线外壳形状。`Boat.tscn:82-91` 中隐藏的 `SailingBoat8m` collider 被禁用；所以本次静态检查**没有确认活动动力艇可直接给水下鱼运动使用的 hull collider**。实施前应查明各船型可用的真实船体碰撞或为每种 hull profile 提供船体外形/水线查询。不要把甲板多边形或固定半径当成所有船型船壳。

### 4.5 鱼竿、声音与显示

船钓竿有自定义 `boat_fishing_rod_bend.gdshader`，`_set_rod_bend_angle()` 接收角度设置（`boat_fishing_casting_system.gd:14, 1865-1873`）。可以以 `tension_ratio` 平滑映射竿弯、冲刺短抽和卸力回弹；这只影响视觉。不要把 rod angle/动画回弹送回求解器。

`FishingRodSystem` 提供 shared one-shot/loop 音频接口，且船钓已经按 `boat_fishing` owner 控制 loop（`boat_fishing_casting_system.gd:2648-2666`）。可以复用该音频播放资源/淡入淡出能力，但不能复用其自动搏鱼阶段：

- 左键实际 line-in rate > 0：收线音。
- 实际 line-out rate > 0：泄力出线音。
- 收放线都为零：持续 loop 停止。
- 单次 Hook Strike、line break、落水和成功事件由状态事件触发，不能逐帧触发。
- 结算成功一条或一批只播一次 `catch_success`。

正常 UI 不显示张力条/鱼体力条/危险百分比。泄力变化时短暂显示档位或百分比；串钩保留挂鱼数量。F3 通过只读 snapshot 显示实时 N、承载力 N、泄力阈值、线速、线长、逐鱼力/体力/状态和危险计时/断线原因。

## 5. 建议的状态机与事件流

推荐保留现有抛投/等待 `CastState`，增加一个船钓 `FightPhase` 子状态，不另造一套 cast 状态：

```text
READY → CHARGING → CASTING → WAITING
                                  │ bite reservation
                                  └→ BITE_APPROACH → HOOKED/FIGHTING
                                                        │ player reels / fish pulls
                                                        ├→ FIGHTING (ongoing)
                                                        ├→ LINE_BROKEN → recovery/reset
                                                        └→ near-boat safe zone
                                                             → LANDING → SETTLEMENT
                                                             → CATCH_PRESENTATION → READY
```

单钩在接触后创建一个 fight participant。Sabiki 每次接触给对应钩位增加 participant，**首鱼不自动收线、五钩满也不自动收线**；其他空钩只要仍在水中且 Authority 有剩余可用资源，就继续自然判定。玩家按住左键才产生主动卷线；鱼主动负荷在按钮松开时也继续作用。玩家一开始统一收串钩或钩组离水时，冻结新咬钩和该批 participants；只有钩组到达船边安全提鱼点才执行批量结算。

“主动收线”不是 `begin_retrieval` 的固定动画开关，而是连续 solver input。当前 `FishingEncounterSystem.begin_retrieval()` 将全局 Encounter state 改成 RETRIEVING，并发 `retrieval_started`；拖钓竿系统会响应这一事件，因此船钓不宜在玩家刚按住左键时调用此共享入口。建议增加 boat-only session/lifecycle 方法，或者只在船钓安全 landing 阶段调用共享结算内核，并阻断拖钓 presentation 消费船钓事件。

## 6. 输入建议

**已确认**：左键 `boat_fishing_cast` 已被蓄力/收线共用；F (`boat_fishing_pay_out`) 当前主动放线并且也用于港口服务；E 是 `port_interact`；O 是 `god_view_toggle`/摄像机切换；A/D 舵向、W/S 动力、空格暂停、T 自动驾驶、Z/X/J/L/T 等帆船操纵（`project.godot:38-155`，相机处理见 `boat_follow_camera.gd:89`）。不要挪用这些键。

在项目 `InputMap` 和脚本中未找到 Q / R 的绑定（R 只在独立雨效 debug panel 使用，且要求相关 debug panel 收到该事件），因此**建议初始默认 Q = 降低泄力、R = 增加泄力**，按住后按真实 `dt` 连续增减，速度设置成低速连续调节。实现时只在船钓搏鱼且指针不在 UI 时响应，并调用 `get_viewport().set_input_as_handled()`；将其做成 InputMap 动作，便于后续重绑。按键变化只短暂显示 `DRAG xx%`，不显示张力值。

若希望完全避免按键布局差异，可由 HUD 加一个小型拖动 slider 作为可访问替代；它直接修改同一 drag setting，不形成第二套 drag 状态。不要用 F（放线）、鼠标滚轮（UI 可能滚动）或 E/O 复用。

## 7. 拖钓隔离边界

拖钓保持当前 `FishingEncounterSystem` 的拖钓概率、`FishingFightProfile` 固定 presentation 脉冲、`FishingRodSystem` 自动回收/摄像机/鱼竿/线声音和任务路径。新船钓系统只共享：鱼种配置身份、鱼群 Authority 候选/人口、catch 结果类型及公共音频播放资源。新船钓系统独有：手持抛投、钩位坐标、BoatFight participant/solver、drag 输入、线 break、船边安全区和 boat fishing landing。

不要：把 `FishingFightProfile` 的拖钓时间序列作为船钓力学；让船钓设置 `FishingEncounterSystem.State.RETRIEVING` 后再让拖钓系统自动完成；让通用 `fish_hooked` 自动启动船钓/拖钓两套竿；让拖钓线长或船速控制 boat fight。复用时优先复用纯数据/Authority、几何 helper 与音频接口，避免共用状态所有权。

## 8. 分阶段文件级实施计划

| 阶段 | 预计文件/改动边界 | 最少验证与验收 |
|---|---|---|
| **P6.4.2 鱼力量/体力模型** | 新增 `scripts/boat_fishing_fight_profile.gd` 与运行时 participant/state 类；为可船钓物种增加独立资源或 profile 引用（优先覆盖 `herring`、`sea_trout`、`needlefish`）；不动 `FishingFightProfile` 和拖钓资源。基于 `FishingPendingCatch.body_length_m` 初始化属性。 | 纯逻辑固定 seed/固定 `dt`：三物种及体型上下界力量排序；burst/恢复和 stamina 始终限幅；不同 catch ID 事件可复现；debug fish 不进入 Authority。无场景/鱼群压力测试。 |
| **P6.4.3 张力/泄力/实际线速** | 新增 `scripts/boat_fishing_fight_solver.gd`（纯求解）；给 `BoatFishingRigProfile` 或新的线配置提供额定断裂力和拖力范围；`BoatFishingCastingSystem` 只增加输入桥接和唯一长度提交点；`project.godot` 注册 drag 动作。 | Solver 单元测试：松开键且鱼力≤drag 时长度不缩短/不凭空放线；鱼力越过 drag 会出线且按键不强迫收线；改变 drag 的单调性正确；极端 `dt`、拖力边界、burst 峰值和危险清除；FPS 变化不改变指定实秒负荷结果。 |
| **P6.4.4 船钓状态集成** | `boat_fishing_casting_system.gd` 切换单钩/串钩 Hook/Fight/Land；`fishing_encounter_system.gd` 加 boat-specific session/lifecycle/settle API或让共享结算内核可区分 caller；需要时轻量扩展 `FishingPendingCatch` 的会话关联，不改人口数据模型。`FishingRodSystem` 仅隔离 boat method 的事件消费，不改拖钓路径。 | 使用确定 Authority/现有 F3 测试鱼完整跑：钩上、手动收线、鱼拉线、松键停收、断线取消、到船边结算；Sabiki 1–5 鱼继续独立累计、满钩不自动收、一次批量结算；切换/取消不双结算、不遗留 reservation；测试鱼无自然人口扣减。 |
| **P6.4.5 视觉/音效/操作反馈** | `boat_fishing_rod_bend.gdshader` 和 casting 只读 tension ratio；复用外部 fishing audio loop/one-shot，但按真实线速；`boat_hud.gd` 显示泄力短提示及自然状态；本阶段若需新增 UI 字符串，修改中英文翻译；`fishing_debug_panel.gd` 增加只读 Fight Snapshot。 | 运行游戏人工检查：Hook Strike、弱拉/冲刺、出线/收线/静止、断线和 lift 的竿弯/鱼/声音；单/串钩逐只挂鱼；第一人称与 O 视角切换；F3 开/关时逻辑相同，关闭不做额外逐帧诊断。代码检查不替代视听验收。 |
| **P6.4.6 边界和平衡** | 仅调 boat-fight profiles 与线/drag 配置；若船型几何资料不足，再更新对应 hull profile/安全提鱼查询；不改渔获概率和拖钓规则。 | 单钩、Sabiki 1/3/5 鱼；小/大体型、低/高拖力、连续高负荷/冲刺、断线恢复、活动退出/场景卸载、船边/船体安全、两种视角；以重复种子报告搏鱼时间、断线率和各鱼体力轨迹。对 FishingRodSystem 做拖钓自然中鱼/自动收获回归。 |

顺序合理：先验证鱼行为数据，再做独立数值求解，第三阶段才接入现有 cast/Authority；视觉/声音最后读取稳定的 solver snapshot。唯一需提前准备的是线承载力的统一单位与第一版默认标定，否则 P6.4.3 无法给 drag 值、阈值和断线时间做有意义的测试。

## 9. 主要风险与待确认事项

1. **单位尚未有基线**：当前 rig/species resource 没有 line rating、pull force 或 drag setting。先选 N 作为内部游戏标定单位，并确定第一版 `F_break` 与可用 drag 区间；若这些值不明确，70/85/100/120% 的危险带只能是比例，无法转为可调力。
2. **共享 Encounter 事件会启动拖钓表现**：`FishingRodSystem._on_fish_hooked()` 对所有 pending 启动真实 presentation。此前应避免让 boat catching 继续触发拖钓竿的事件消费者。必须有 boat 专用事件隔离，并保留公共 Authority。
3. **Sabiki 已确认鱼在“等待继续挂鱼”时与批量收线状态共用一组 catch 列表**：新流程需区分“仍可加鱼的会话”与“已冻结准备提鱼的批次”，否则玩家收线后仍可能新增 fish、或过早停掉空钩 hazard。
4. **单钩当前的 reservation 是 Encounter 内 pending/cooldown，不是 Authority 持久锁**：结算时 Authority 会再次验证并扣减；搏鱼期间如学校被生态/其他操作移除，需保持现有验证和 cancel 语义，不能承诺一个不可失效的个体鱼实体。
5. **可用船体形状未确认**：当前甲板 walkable polygon 只适合人物/线视觉，不是水线体积。需查清 powered boat 的实际 hull mesh/collider 数据，或定义 hull-specific waterline profile，防止鱼穿船并计算“不能主动朝船游”的参考点。
6. **完整场景中的“提鱼点”和破线后装备状态未定义**：规则明确鱼到船边自动提鱼、断主线整副鱼获丢失；但没有指定哪个舷侧/甲板落点，以及破线后是否立即恢复一副新钓组或留下断线空杆。建议第一版仅短暂显示断线/卸力，取消未结算鱼，回到可操作状态；不增加自动补装费用或永久损伤。最终恢复状态需在 P6.4.4 之前定下。
7. **Sabiki 空钩继续中鱼与玩家正在收线并存**：这是已确定规则，但目前采样只在 `WAITING`/`SABIKI_HOOKED_WAITING` 状态调用。P6.4.4 要将 hazard 更新与 fight frame 解耦，不能因状态改成 `FIGHTING` 而意外停掉其他空钩，也不能在钩组已出水后继续抽样。
8. **显示时间**：用户规则没有要求随全局游戏时间加速搏鱼。建议按现实 `dt` 管理 stamina、burst、line rate、danger timer 和输入，以避免世界时间倍率改变玩家反应；鱼群生态和 catch timestamp 仍使用当前 world-time Authority。

## 10. 本阶段检查范围与未做项

完成了脚本、资源、主船场景、HUD、输入映射和 Authority 调用的静态阅读。未运行自动测试、Godot 场景或实际游戏；未验证力数值、可视表现、声音听感、实际活动船体碰撞或用户设备帧率。未修改任何正式玩法代码、资源配置、输入映射或测试；本报告是本任务唯一新增文件。
