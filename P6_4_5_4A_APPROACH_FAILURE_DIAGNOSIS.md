# P6.4.5.4a — 船钓追饵失败与操作锁定诊断

## 结论摘要

已确认两件不同的事：

1. **操作锁定是当前代码明确执行的状态规则。** 开始 `BITE_APPROACH` 时，系统把输入所有权交给自动控制，清除玩家收线、放线和瞄准状态。这个期间左键收线、F 放线、Q/R 泄力、切换钓组和普通收线按钮都不可用。它不是鱼在拉线，也不是 Solver 在自动收线。
2. **海鳟追逐可以因鱼群活动深度变化而被取消。** `BITE_APPROACH` 每帧都用 Authority 当前有效活动深度重新验证鱼群与鱼钩的垂直距离。海鳟群从表层进入下潜状态后，垂直差超过约 2.94 m 会立即取消这次预约，即使鱼还在以正常速度接近。

在 16 FPS 的完整主场景测试中，9 m、深度稳定的真实 Authority 海鳟从约 8 m 外开始游动，11.312 秒后正常接触鱼钩。另一个使用同一完整状态机、只在内存测试夹具中把鱼群表层剩余时间设为 0.6 秒的运行，在 6.688 秒因 `activity_depth_mismatch` 取消；鱼嘴距钩仍有 3.342 m，主线长度前后保持 5.864 m。这证实深度变化取消路径确实可触发，但**不能证明玩家 Mac 上那几次失败一定就是这个原因**，因为当前没有那次实机的逐次运行日志或可确认的构建版本。

因此，低帧率本身、追逐超时或追逐阶段的自动收线都不是现有证据支持的主要解释。最符合当前代码与复现结果的失败原因是：**目标海鳟群的有效活动水深在追逐期间变化，超过了持续资格检查的垂直容差；失败后系统回到等待并重新评估，所以以后还能重新出现一次新的接近。**

## 1. Single Jig 实际调用链

1. `BoatFishingCastingSystem._process()` 只有处于 `WAITING` 或 `SABIKI_HOOKED_WAITING` 时才运行 `_update_natural_bite_judgement()`；自然中鱼资格按约 0.5 秒采样。见 `scripts/boat_fishing_casting_system.gd:1325-1337`、`:110`、`:1416-1427`。
2. 单钩查询将亮片实际鱼钩世界位置、水深、拟饵相对速度和当前钓组传给 `FishingEncounterSystem.evaluate_boat_fishing_candidates()`。候选检查鱼种/拟饵、可用数量、动作、深度和球形追饵距离。候选中的 `activity_depth_m` 是评估时的有效活动深度。见 `scripts/boat_fishing_casting_system.gd:1548-1574`、`scripts/fishing_encounter_system.gd:390-455`、`:457-509`。
3. Encounter 给合格 SCHOOL_TARGETED 候选创建反应时间，再扣除估算的实体追逐时间。`pre_approach_seconds = max(0, total_seconds - approach_seconds)`。见 `scripts/fishing_encounter_system.gd:887-905`、`:914-927`。
4. 反应结束后，Encounter 返回一个含 `trigger_mode = SCHOOL_TARGETED` 和钩位索引的候选。当前源码已包含这些元数据。见 `scripts/fishing_encounter_system.gd:959-975`。
5. `_begin_bite_event()` 向 Encounter 创建唯一 pending catch，读取当前 Authority 学校中心，在群中心朝鱼钩方向靠近约 1 m 的位置设置鱼的起点，按鱼种速度启动接近，并设置超时。随后进入 `BITE_APPROACH`。见 `scripts/boat_fishing_casting_system.gd:2047-2129`。
6. 每帧 `_advance_bite_approach()` 先验证 pending catch 所属学校和追饵资格，再以鱼种速度将鱼嘴位置移动向当前鱼钩；仅当鱼嘴到钩距离不超过 0.08 m 才调用 Authority 确认。见 `scripts/boat_fishing_casting_system.gd:2133-2181`。
7. 确认成功后，Encounter 将 pending catch 变为 `HOOKED`，船钓进入玩家控制的 `FIGHTING`。见 `scripts/fishing_encounter_system.gd:1256-1283`、`scripts/boat_fishing_casting_system.gd:2214-2251`。

## 2. APPROACH 时限与游速是否相配

Sea Trout 当前配置为：游速范围 `0.4–1.0 m/s`，表层深度 `0.5–5.0 m`，深层深度 `6.5–12.0 m`，垂直活动速度 `0.5 m/s`，表层停留 `45–100 s`。见 `resources/fish_species/sea_trout.tres:25-35`。

追逐起点偏移量为 `min(school_wander_radius × 0.2, 1.0 m, 目标距离 × 0.2)`。Sea Trout 的 `school_wander_radius_m` 是 5.2 m，所以鱼群中心到鱼钩 9 m 时，鱼从中心向鱼钩方向偏移 1 m，初始鱼嘴到钩约 8 m。追逐平均速度为 `(0.4 + 1.0) / 2 = 0.7 m/s`，静态目标预计需要 `8 / 0.7 = 11.43 s`。超时为 `max(15, 2 × 11.43 + 5) = 27.86 s`。见 `scripts/boat_fishing_casting_system.gd:2078-2107`。

因此 9 m 场景下的允许时间约为预期实体追逐时间的 2.44 倍；没有另一个更短的 BITE_APPROACH 状态计时器。`_state_elapsed` 在状态切换时重置，但此状态的超时实际只由 `_bite_elapsed > _bite_approach_timeout_seconds` 控制。接触在时限检查后进行，阈值为 0.08 m。见 `scripts/boat_fishing_casting_system.gd:2133-2181`。

Encounter 的 9 m 反应时间估算也不是额外的 2–10 秒强制等待：该距离下实体追逐估算约 11.43 秒，大于边缘反应上限 10 秒，故预接近等待被截为 0。玩家看到“鱼正在靠近”后，接下来主要是在等鱼实体移动，不是仍在等待随机 Hazard。见 `scripts/fishing_encounter_system.gd:887-900`、`:914-927`。

## 3. APPROACH 期间鱼钩与线长是否移动

`_process()` 在 `BITE_APPROACH` 只调用 `_advance_bite_approach(delta)`；不会调用 `_update_waiting_bait()`，也不会调用搏鱼 Solver。见 `scripts/boat_fishing_casting_system.gd:1325-1351`。

权威 `_line_paid_out_length_m` 在等待阶段仅由手动收放线写入，在搏鱼阶段由 Solver 路径写入，在最终回收动画中由回收路径写入；没有 BITE_APPROACH 写入点。见 `scripts/boat_fishing_casting_system.gd:2421`、`:2924`、`:3649-3655`、`:3761-3774`。`_update_reel_visual_and_audio()` 只读取线长差以驱动线轮表现，不拥有线长。见 `scripts/boat_fishing_casting_system.gd:3986-4023`。

单钩的 `_bait_world` 在 BITE_APPROACH 期间不被等待水下运动更新。鱼钩挂点为 `_bait_world + lure_basis × hook_tip_offset`；拟饵视觉姿态仍逐帧更新，因此鱼钩尖可以围绕亮片中心有很小的视觉位移，但不会由玩家收线、放线或线长求解器带动。亮片钩尖偏移长度约 0.0465 m（最大相反姿态间的几何位移不超过约 0.093 m）。见 `scripts/boat_fishing_casting_system.gd:38`、`:882`、`:4303-4307`、`:4584-4598`。

实测的 9 m Sea Trout 固定深度运行中，首次鱼钩样本速度为 0.031 m/s，之后逐秒采样为 0；线长一直为 5.864 m。船体移动或波浪可能让竿尖/动态水面及鱼群相对位置发生变化，但不是 BITE_APPROACH 在缩短权威线长。

## 4. 鱼的实际运动与接触阈值

`_advance_bite_approach()` 使用真实 `_process` delta 调用 `advance_fish_pursuit_world()`，核心是 `current_mouth.move_toward(hook_world, speed × dt)`。鱼模型姿态以该鱼嘴世界坐标和 profile 嘴部锚点定位，接触距离也直接使用这个鱼嘴状态与同一帧鱼钩挂点计算。见 `scripts/boat_fishing_casting_system.gd:2144-2157`、`:1950-1984`、`:3243-3248`。

在固定 16 FPS 的完整主场景 Sea Trout 运行中，鱼嘴到鱼钩距离逐秒从约 7.96 m 降到 0.222 m，并在 11.312 秒达到确认；鱼速约 0.7 m/s。0.08 m 接触半径可达，鱼嘴尚未接触时没有提前确认。低 FPS 运行每帧鱼移动约 `0.7 / 16 = 0.04375 m`，小于 0.08 m 接触阈值，且 `move_toward` 在末端会直接停到钩点，不会因为低帧率跨过目标而漏判。

此结果针对固定目标、固定活动深度。它不排除 GPU 帧时间尖峰、船体移动或水面变化参与某次实机失效，但没有证据表明 16 FPS 本身导致失败。

## 5. 已复现的完整时间线

### A. 深度稳定：成功

在真实主场景、真实 Authority Sea Trout、9 m 学校中心距离、固定 16 FPS 下：

| APPROACH 已用时间 | 鱼嘴到钩距离 | 海鳟有效深度状态 | 线长 |
|---:|---:|---|---:|
| 0.062 s | 7.958 m | near_surface，1.527 m | 5.864 m |
| 1.062 s | 7.253 m | near_surface，1.527 m | 5.864 m |
| 4.062 s | 5.144 m | near_surface，1.527 m | 5.864 m |
| 8.062 s | 2.331 m | near_surface，1.527 m | 5.864 m |
| 11.062 s | 0.222 m | near_surface，1.527 m | 5.864 m |
| 11.312 s | 接触并确认 | FIGHTING | 5.864 m |

运行入口：`godot --headless --fixed-fps 16 --path . --script /private/tmp/test_p6_4_5_4a_sea_trout.gd`。该临时脚本基于现有主场景集成测试，筛选真实 Authority 海鳟，不改项目源码。

### B. 表层活动结束：按当前有效规则取消

第二次运行保持 9 m Sea Trout 场景，但在内存测试夹具中把海鳟表层剩余活动时间设为 0.6 s，以确定性地观察活动深度变化。此设置只属于 `/private/tmp` 测试脚本，未写入资源或正式参数。

| APPROACH 已用时间 | 鱼嘴到钩距离 | Authority 有效深度 | 结果 |
|---:|---:|---:|---|
| 0.062 s | 7.958 m | 1.527 m，near_surface | 接近开始 |
| 1.062 s | 7.253 m | 1.759 m，descending | 有效 |
| 3.062 s | 5.847 m | 2.759 m，descending | 有效 |
| 6.062 s | 3.737 m | 4.259 m，descending | 有效，距垂直容差边缘约 0.19 m |
| 6.688 s | 3.342 m | 4.571 m，descending | `activity_depth_mismatch`，pending 已释放，回到 WAITING，线长仍为 5.864 m |

Sea Trout 默认 `school_activity_radius_m = 4.2 m`，持续追逐垂直容差为 `clamp(4.2 × 0.7, 1.2, 3.0) = 2.94 m`。钩深约 1.417 m，Authority 活动深度 4.571 m，差约 3.154 m，故在尚余约 3.342 m 鱼嘴距离时取消。见 `scripts/fish_species_profile.gd:71` 和 `scripts/boat_fishing_casting_system.gd:2022-2029`。

运行入口：`godot --headless --fixed-fps 16 --path . --script /private/tmp/test_p6_4_5_4a_sea_trout_depth_transition.gd`。它运行真实主场景、FishingEncounter、Authority 与 CastingSystem；只直接调整一条测试 School 的运行时深度周期，目的是复现路径，不代表自然出现该时序的实机录屏。

## 6. 为什么会再次显示“鱼正在靠近”

这不是同一个 pending catch 被同时创建多份。Encounter 在已有 pending catch 时拒绝新的触发，取消时 `_cancel_pending()` 释放当前记录并发出取消事件。见 `scripts/fishing_encounter_system.gd:715-720`、`:1286-1295`、`:1714-1719`。

取消回调清理鱼模型、participant/session 与输入所有权，然后将 CastingSystem 状态恢复为 `WAITING`；进入 WAITING 又会清空该钩位的 target reaction。见 `scripts/boat_fishing_casting_system.gd:3149-3170`、`:4622-4630`。等待阶段继续每 0.5 秒重新做候选评估。只要同一鱼群再次满足当前深度、动作、可用鱼数量和球形追饵范围条件，Encounter 就可以新建一个 reaction 和新的 pending catch。9 m Sea Trout 的预测实体追逐时间超过反应上限，故新的反应通常没有额外预等待。

所以重复提示是“取消后释放，再由新一轮资格评估重新触发”，不是一条 pending 被重复确认。若资格持续失效，它不会立刻重试；海鳟活动深度再次进入有效层后，才可能再出现。

## 7. 失败原因记录是否能在实机看到

当前 `BITE_APPROACH` 主要的主动取消原因由 `_school_pursuit_still_valid()` 返回：

- `school_unavailable`
- `unknown_species`
- `pursuit_range_exited`
- `activity_depth_mismatch`

此外，追逐超过计算出的最大时间会给出 `approach_timeout`。在接触确认时，Authority 还可能以 `school_unavailable_during_bite` 释放 pending。见 `scripts/boat_fishing_casting_system.gd:2011-2030`、`:2175-2177` 和 `scripts/fishing_encounter_system.gd:1256-1272`。

CastingSystem 会把主动取消原因短暂写入 `last_pursuit_failure_reason`，但 `_on_authority_catch_cancelled()` 的 `_reason` 参数被忽略；返回 WAITING 后，下一次候选采样会整体重建 `_last_natural_bite_diagnostics`，不包含上次失败原因。见 `scripts/boat_fishing_casting_system.gd:2184-2196`、`:3149-3170`、`:1588-1612`。F3 当前只渲染活动中的接近快照，不渲染 `last_pursuit_failure_reason`。见 `scripts/fishing_debug_panel.gd:1192-1197`、`:1386-1401`。

这是已确认的诊断可观测性缺口：普通玩家 HUD 只显示“鱼正在靠近”，失败后回 WAITING；即使短暂存在原因，F3 通常也来不及保留它。

## 8. 为什么鱼线最终会全部收回

追逐期间没有手动等待物理、Solver 或最终回收调用，模拟中的线长保持不变。已复现的成功与取消两条路径都保持 5.864 m。

回到 WAITING 后，线长仅在 `_manual_reeling` 时递减，或在玩家按 F 时增加。若手动收线将终端连接点拉到竿尖的回收余量内，系统才进入 `RETRIEVING`，由该最终回收动画把线长设为 0。见 `scripts/boat_fishing_casting_system.gd:3649-3657`、`:3703-3708`、`:3737-3781`。

另外，HUD 的“结束船钓”活动按钮在 BITE_APPROACH 期间仍可用；结束活动会清除本次 cast。见 `scripts/boat_hud.gd:578-582`、`:805-817`。因此，**“线全部收回”不能由本次追逐逻辑单独解释**；若实际线长归零，代码证据指向后续手动收线触发最终回收，或结束活动/清 cast。没有实机输入历史，无法判定玩家当时具体触发了哪一项。若玩家并未继续输入且没有结束活动，当前代码不应在取消瞬间自动收回线。

## 9. 玩家为什么不能操作

这是当前明确的输入所有权设计：`_begin_bite_event()` 调用 `set_automatic_control_owned(true)` 并清空手动收线、放线和竿尖瞄准状态。该函数注释说明它本身不推进自动搏鱼状态，但会占用输入。见 `scripts/boat_fishing_casting_system.gd:935-950`、`:2117-2127`。

- 左键收线的 `set_manual_reeling()` 只接受等待状态或已确认搏鱼的 FIGHTING 状态，并拒绝自动控制所有权；BITE_APPROACH 两项都不满足。见 `scripts/boat_fishing_casting_system.gd:540-552`、`:2037-2039`。
- `BITE_APPROACH` 的 `_process()` 分支只推进追逐，不处理等待阶段或搏鱼阶段的玩家控制。F 放线也只接受等待或 FIGHTING。见 `scripts/boat_fishing_casting_system.gd:1340-1351`、`:1243-1287`。
- Q/R 只在已建立 fight session 后进入泄力调节处理，因此鱼接触鱼钩前没有可调泄力。见 `scripts/boat_fishing_casting_system.gd:1266-1271`、`:2361` 起的搏鱼控制路径。
- HUD 收线按钮只允许 WAITING、SABIKI_HOOKED_WAITING、FIGHTING；切换钓组则只在 READY 可用。见 `scripts/boat_hud.gd:831-844`、`:917-926`。
- 结束船钓按钮仍然可用。抛竿释放时船上角色移动锁开启，最终回收完成或清除 cast 时解除；这是抛竿会话锁定，不是鱼的活动。见 `scripts/boat_fishing_casting_system.gd:490`、`:3704-3710`、`:3774-3781`。

## 10. 根因判断、修复建议与限制

### 已由当前代码确认

- BITE_APPROACH 禁止常规收放线与泄力操作。
- BITE_APPROACH 不自动修改 `_line_paid_out_length_m`。
- 9 m 海鳟的静态追逐时限充足，当前 16 FPS 确定性运行能够到达接触。
- 追逐期间重新检查 Authority 活动深度，跨过 2.94 m 垂直容差会取消。
- 取消释放 pending、回到 WAITING，并重置 reaction；后续合格样本能创建新的尝试。
- 上一次失败原因不会稳定保留在 F3。

### 已用完整状态机复现，但需要区分测试前提

- 在一条 9 m 海鳟学校即将结束表层活动时，实时水深变化能在 6.688 秒触发 `activity_depth_mismatch`。这证明失败路径真实可达，不是静态函数推测。
- 固定深度时同一类 9 m Sea Trout 运行在 11.312 秒成功。两种结果的差异来自 Authority 深度活动变化，不是速度或线长。

### 尚未证实为用户 Mac 那次运行的事实

- 实机那三次接近是否分别以 `activity_depth_mismatch`、`pursuit_range_exited`、超时或 pending 失效结束。
- 实际游戏包是否与当前工作区源码完全一致。
- 最终回收是否因玩家重新按住左键，或因玩家结束了船钓活动。
- GPU 画面中的鱼嘴锚点误差与每帧实际值；Headless 不能代替视觉检查。

### 建议的最小后续修复方向

1. **将深度资格与已开始追逐的存活条件分开。** 深度匹配应决定是否允许建立目标鱼和 pending；成功预约并离群追逐后，不要仅因学校群体代表深度继续移动而立即取消。继续验证 School/pending 的有效性和当前追饵范围；追逐鱼本身仍按实际速度追向当前钩位。重点文件：`scripts/boat_fishing_casting_system.gd`，必要时只补充 `scripts/fishing_encounter_system.gd` 提供的候选快照字段。
2. **把输入锁定从“追逐接近”与“中钩搏鱼”区分开。** 若设计要求玩家在接近时仍可调整拟饵，应允许相应的收线/放线输入并继续用更新后的钩位追踪；超出球形追饵范围时再按明确规则取消。当前锁定来自 `_automatic_control_owned` 和 BITE_APPROACH 不属于手动控制状态。重点文件：`scripts/boat_fishing_casting_system.gd`、`scripts/boat_hud.gd`。
3. **持久保存最后一次追逐终止信息。** 保留 catch ID、School ID、钩位、结果原因、经过时间、结束时鱼嘴到钩距离、当时钩深/Authority 深度、范围值、pending 释放结果和线长前后值；不能在下一次 0.5 秒采样时覆盖。重点文件：`scripts/boat_fishing_casting_system.gd`、`scripts/fishing_debug_panel.gd`。

本轮没有实施上述任何修复。

## 测试与交付边界

- 运行 `godot --headless --fixed-fps 16 --path . --script tests/test_p6_3_1_single_jig.gd`：退出码 0，测试输出 `failures=0`。这是完整主场景与状态机覆盖，但在 Headless 模式运行。
- 运行 `/private/tmp/test_p6_4_5_4a_sea_trout.gd`：真实 Authority Sea Trout、9 m、实际 CastingSystem 状态机成功接触；记录 11.312 秒时间线。
- 运行 `/private/tmp/test_p6_4_5_4a_sea_trout_depth_transition.gd`：只对测试夹具里的 Authority School 做内存状态改动，复现 `activity_depth_mismatch` 取消与 pending 释放；不是自然随机时序或 GPU 画面验收。
- 没有运行 GPU 实机画面测试；没有修改任何正式游戏逻辑、资源、参数或仓库测试。
- 临时诊断脚本保存在 `/private/tmp`，不属于项目文件。

### 若需确认玩家那次 GPU 实机失败

当前 F3 只显示活动中的追逐快照，取消原因不会稳定保留；无需改变玩法即可先用录屏补足证据：

1. 在 F3 Fishing 页观察 `active_pursuit_approach`，从“鱼正在靠近”出现时开始录屏，直到它回到等待或进入搏鱼。
2. 记录每次出现时的 `school_id`、`hook_index`、`elapsed_seconds`、`actual_mouth_to_hook_distance_m`、`speed_mps`、`timeout_seconds`，并抄下右侧 HUD 的鱼钩深度与放线长度。
3. 同时记录 F3 鱼群有效活动深度/状态；若提示消失，记下最后一帧的鱼嘴距离和鱼群深度。若这两个值在取消前分离约 2.94 m，符合本报告复现的 `activity_depth_mismatch` 路径；若距离持续下降至 0.08 m 内，则应转查确认/Authority 路径。
4. 不需要等待完整环境随机周期；先在同一海鳟群、同一深度条件下重复一次，并保持不操作收放线。若收线长度在取消前后发生变化，也一并记录，这可区分追逐逻辑与随后手动回收。

这些是实机取证步骤，不是已经观察到的 Mac 运行结果。当前没有可回看的逐帧实机记录，因此不能把受控 Headless 复现直接等同于用户现场根因。
