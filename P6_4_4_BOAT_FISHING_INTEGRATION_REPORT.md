# P6.4.4 船钓搏鱼系统正式集成报告

## 结果摘要

单钩亮片和 Sabiki 串钩现已接入 P6.4.2 participant 与 P6.4.3 solver。玩家在中鱼后手动收线，鱼力超过当前泄力时由 solver 放线；到达船边安全边界后才进入提鱼与 Authority 结算。单钩不会再使用旧的拖钓自动搏鱼时间线。串钩每条已确认挂鱼独立挣扎，空钩在玩家收线期间仍继续参与自然中鱼，五钩全满也不会自动收线。

实现维持 `_line_paid_out_length_m` 为船钓唯一权威线长。搏鱼每步由 solver 返回 `line_delta_m`，仅在 `BoatFishingCastingSystem._advance_boat_fight()` 提交一次；其他阶段原有抛投、等待和空钩回收仍按各自逻辑更新同一字段。

## 修改文件

- `scripts/boat_fishing_casting_system.gd`：participant/solver 生命周期、玩家控制、鱼和钩位位置约束、船边提鱼、断线与取消。
- `scripts/fishing_encounter_system.gd`：船钓 pending 确认、Sabiki batch 的活动互斥、预约释放和原子批量结算边界。
- `scripts/fishing_rod_system.gd`：共享事件按 `fishing_method` 隔离，拖钓 presentation 忽略船钓事件。
- `scripts/fishing_player_panel.gd`：拖钓结果面板只消费拖钓结果和取消事件。
- `scripts/boat_hud.gd`：将现有按住式按钮作为左键的同一手动收线入口；显示挂鱼数、线长/深度和当前泄力。
- `project.godot`：加入可重绑的船钓泄力输入动作。
- `resources/translations/fish_species.csv`、对应英文和简体中文 translation 资源：船钓状态与泄力提示所需的本地化文本。
- `tests/test_p6_3_1_single_jig.gd`、`tests/test_p6_3_2_sabiki_multi_catch.gd`：扩展正式搏鱼、断线、活动退出与拖钓隔离检查。

P6.4.2/6.4.3 的模型、solver、配置资源及其既有测试没有为集成而改写。

## 状态和操作

抛投主状态仍为 `READY → CHARGING → CASTING → WAITING`。自然中鱼后仍先走既有鱼接近/咬钩步骤；单钩在 Authority 确认咬钩后注册 participant 并进入 `FIGHTING`。串钩继续处于 `SABIKI_HOOKED_WAITING`：每个钩位确认时加入自己的 participant，但不启动自动收线。状态枚举和按状态更新位于 `BoatFishingCastingSystem`（`scripts/boat_fishing_casting_system.gd:12`, `1024-1089`, `1274-1383`, `1617-1699`）。

- 左键按住：搏鱼期间主动尝试收线；松开后线长保持，除非鱼力克服泄力而被动出线。空钩等待时继续使用原手动收线行为。
- `Q`：降低泄力；`R`：提高泄力。两者经过 InputMap，在搏鱼状态、没有菜单/GUI 焦点时按真实时间连续改变 `[0,1]` 的档位。每秒变化率为 `fight_drag_adjustment_per_second`，默认 `0.35`（`project.godot:48-56`; `scripts/boat_fishing_casting_system.gd:79`, `1723-1737`）。
- `F` 仍是正常等待时的主动放线。搏鱼中 `F` 不直接写线长，鱼的被动出线只由 solver 决定。
- HUD 按住按钮也调用同一 `set_manual_reeling`，不再提供一条“自动收获串钩”的第二收线流程（`scripts/boat_hud.gd:756-763`, `773-829`）。

搏鱼按 `Time.get_ticks_usec()` 得到真实时间步。participant 更新、快照读取、solver 求解、单次线长提交、钓组更新、鱼位置约束、断线/到船边检查按固定顺序运行。暂停恢复和窗口失焦会重置时间基准，避免把失焦时间累加进搏鱼（`scripts/boat_fishing_casting_system.gd:241-247`, `1710-1788`）。

## participant、solver 与线长

participant 只从 `hook_confirmed` 的 `FishingPendingCatch` 初始化，沿用 catch ID、钩位、物种、体长、debug 标志；体型不会重抽。鱼种有专属 profile 时使用专属资源；未配置的可捕获鱼种使用 generic profile 副本，并按鱼种体长范围中值设置参考长度，同时只警告一次（`scripts/boat_fishing_casting_system.gd:1663-1699`; `scripts/boat_fishing_fight_participant.gd:39-77`; `scripts/boat_fishing_fight_profile_catalog.gd:19-45`）。

单钩只有一个 participant；Sabiki 每个已确认钩位最多一个 participant，整个串钩共用一个 solver session，数量上限沿用 `BoatFishingFightSolver.MAX_FISH_PARTICIPANTS`。收线方向由实际竿尖到钓组的方向提供，solver 决定阻力、张力、出线/收线速度和断线危险。线长写入点在搏鱼更新中紧邻 solver 调用，使用 `line_before + line_delta_m` 并限制在船边安全最小值和最大线长之间（`scripts/boat_fishing_casting_system.gd:1740-1788`; `scripts/boat_fishing_fight_solver.gd:54-63`, `119-193`）。

默认标准配置 `resources/boat_fishing/line_profiles/standard_boat_fishing_line.tres`：主线承载力 `68 N`，泄力 `4–52 N`，初始设置 `0.30` 即 `18.4 N`，主动收线基速 `0.65 m/s`，最大被动出线 `2.4 m/s`。配置沿用 P6.4.3 数值，本轮没有重新平衡（资源 `:7-15`）。

## 鱼、钩位与船体边界

solver 求得的新线长更新亮片/铅坠位置；Sabiki 支线和五个钩位继续由现有钓组几何从铅坠位置计算。各鱼使用自己的主动游动意图，但把朝向船体的水平分量去除，并限制在对应钩位的支线长度附近；因此主动运动不会增加权威线长，也不会使鱼脱离各自钩位（`scripts/boat_fishing_casting_system.gd:1805-1834`, `1837-1870`）。

当前活动船型公开船长和船宽，但没有在已检查的船钓集成入口中找到可直接用于水下的精确船壳/水线轮廓。实现用船体局部坐标中由船长、船宽和安全余量构成的椭圆保守边界，并把鱼投影到椭圆外；提鱼目标取竿尖到该边界的水侧交点。代码没有把甲板 `walkable_polygon_xz` 当成水下船壳（`scripts/boat_fishing_casting_system.gd:58-60`, `1873-1966`）。

这是防止显见穿船的几何近似，不是真实碰撞形状；在图形运行时里尚未验证所有活动船型、船体摇晃和不同持竿姿态下是否仍无穿模。需要在 P6.4.5/后续视觉验收中对这项近似作实机调校，或接入经确认的船型专属水线轮廓。

## 船边提鱼和 Authority 结算

玩家收线到 solver 的最小线长，即竿尖至船体安全边界的距离后进入 `LANDING`。串钩会先释放仍在接近中的未确认钩位预约，再调用 Encounter 开始同一批 retrieval。提鱼阶段停止搏鱼求解和收放线循环；鱼按钩位索引依次上升越过动态水面，水花音效限频，最后才调用既有 `complete_retrieval()`。单钩复用单鱼结算；串钩调用 Encounter 的批量路径，将自然鱼按 school 聚合后一次性请求人口变化，并为每条鱼产出带独立钩位、体长、重量和 batch ID 的结果（`scripts/boat_fishing_casting_system.gd:1969-2057`; `scripts/fishing_encounter_system.gd:250-256`, `655-714`, `717-799`）。

Authority 在成功结算前不扣减 population；自然 Sabiki reservation 会计入同鱼群可用量，只有确认挂钩的 catch 进入最终批次。debug 鱼标记保留且不改变自然人口。取消未确认的预约会释放本地保留；断线、退出船钓、清理 cast、场景卸载和结算失败都会取消 pending/batch、清除 participant/鱼视觉、重置 solver 和循环音效。`_settled_catch_ids` 与 Encounter 的 batch 生命周期继续阻止重复结算（`scripts/fishing_encounter_system.gd:493-562`, `717-799`; `scripts/boat_fishing_casting_system.gd:284-360`, `2669-2677`, `2059-2154`）。

断线时停止 solver 和线控、释放所有 fish/pending、清除视觉与循环音效，不调用成功结算；短暂 `LINE_BROKEN` 后 `clear_cast()` 恢复 `READY` 和甲板移动（`scripts/boat_fishing_casting_system.gd:2084-2137`）。

## 拖钓隔离

共享 Encounter 仍发出通用鱼钩/结算信号，但拖钓 presentation 在 `fish_hooked`、`retrieval_started` 和 `catch_succeeded` 入口拒绝 `fishing_method == "boat_fishing"`；拖钓面板只跟踪 `trolling` catch ID。Encounter 还会拒绝在船钓 pending、Sabiki reservation 或 batch 尚未结束时启动拖钓，也会拒绝拖钓 stop/cancel 清除船钓 catch。兼容测试覆盖这些活动互斥条件（`scripts/fishing_rod_system.gd:601-607`, `655-670`; `scripts/fishing_player_panel.gd:253-274`; `scripts/fishing_encounter_system.gd:210-240`, `259-270`）。

旧的船钓自动搏鱼时间线 `_advance_auto_fight`、自动移动鱼线至归零的搏鱼路径不再被船钓调用；`FishingRodSystem` 仍保留给拖钓原演出使用。原先供串钩“自动收获”的按钮逻辑已改成统一手动收线输入，五钩全满不会自动收线。共享信号仍存在，但当前拖钓消费者按活动类型过滤，且 Encounter 防止双方同时拥有会话。

## 定向测试

以下命令在 Godot 4.7.2 Headless 实际运行，均退出码 `0`：

| 检查 | 结果 |
|---|---|
| `godot --headless --path . --editor --quit` | 编辑器扫描与脚本类注册完成，无解析错误。 |
| `godot --headless --path . --script res://tests/test_p6_3_1_single_jig.gd` | `failures=0`；覆盖自然/Debug 单钩、Q/R 连续泄力输入、generic profile 回退、手动搏鱼、拖钓视角隔离、Authority 结算和断线无渔获。 |
| `godot --headless --path . --script res://tests/test_p6_3_2_sabiki_multi_catch.gd` | `failures=0`；覆盖多钩独立 participant、空钩继续判定、1/3/5 条鱼批量收获、空钓组释放预约和退出清理。 |
| `godot --headless --path . --script res://tests/test_fishing_p2.gd` | `failures=0`；拖钓及 Encounter 基线。 |
| `godot --headless --path . --script res://tests/test_fishing_p3_2.gd` | `failures=0`；拖钓演出与调试展示基线。 |
| `godot --headless --path . --script res://tests/test_p6_4_2_boat_fishing_fight_model.gd` | `failures=0`；参与者/随机性/挣扎模型回归。 |
| `godot --headless --path . --script res://tests/test_p6_4_3_boat_fishing_fight_solver.gd` | `failures=0`；泄力、张力、断线、多鱼、边界和帧率测试。 |
| `git diff --check` | 通过，无空白错误。 |

Headless 测试会打印项目已有的 bathymetry fixture、重复 translation UID 和 renderer dummy material/ObjectDB 清理警告；测试 generic profile 回退时还会按设计打印“未调校鱼种使用 generic profile”的一次性诊断。这些不导致本次检查失败。Headless 没有渲染设备，不能用来证明实际屏幕上的鱼体/船壳遮挡、动画观感、音效听感或所有姿态无穿模。没有声称完成 READY/搏鱼/提鱼的实际游戏截图验收。

## 已知限制和 P6.4.5 交接

1. 主线/鱼之间仍是受线长和支线限制的简化运动，不是绳索物理；参与者游动方向不是船体碰撞求解。
2. 船体安全区是按船长和船宽推导的保守椭圆，需在实际图形运行时验证，后续可替换为可靠船型专属水线轮廓。
3. 船边提鱼是短暂低成本上升表现，仍需人工检查网格朝向、水面遮挡、船体遮挡及不同钩位出水次序。
4. 本轮复用已有 reel/line-out/drag/splash/success 音频事件，并按实际线长变化驱动；没有新增断线专用音效，也未做音频听感验收。
5. HUD 只加入现有面板能承载的挂鱼数、线况和泄力百分比；完整张力遥测和专用断线反馈留给 P6.4.5。
6. 未运行带 GPU 的实际场景视觉测试，因此船边真实画面状态仍需人工验收。
