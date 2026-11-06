# P6.4.5.4b — 追饵生命周期修复报告

## 结果概述

修复了追逐开始后仍持续用鱼群代表水深校验追逐资格的问题。追逐开始前的 SCHOOL_TARGETED 水深资格保持不变；Authority pending 建立后，追逐鱼不再因鱼群整体下潜而被取消。追逐仍受鱼群有效性、pending 身份、钩位、原追饵球范围和既有超时约束。

增加了只保留最近一次追逐结束结果的运行时快照和 F3 双语诊断。没有改动鱼种半径、游速、接触阈值、超时公式、玩家操作锁定、Authority 结算规则、Ambient 或拖钓。

## 原取消路径与新生命周期

追逐前的候选资格仍由 `FishingEncounterSystem.evaluate_boat_fishing_candidates()` 处理，含鱼种/装备、鱼钩深度、动作、Authority 资源与追饵范围判断（`scripts/fishing_encounter_system.gd:380`）。该入口未修改。

问题出现在 `BoatFishingCastingSystem._school_pursuit_still_valid()`：原追逐期间校验会再次比较钩位深度与鱼群当前活动深度，导致鱼群从表层下潜时返回 `activity_depth_mismatch`。现在共享校验位于 `scripts/boat_fishing_casting_system.gd:2050`，持续保留 pending、School ID/species、Authority School 可用状态、鱼钩有效性、鱼种配置及追饵范围检查，但不再重复做活动深度资格检查。

追逐球心在 pending 创建并启动追逐时记录：单钩在 `:2233` 起始路径保存，Sabiki 在 `:1675` 起始路径为每个钩位分别保存。追逐阶段以该初始三维球心计算追饵半径，因此鱼群代表深度移动不会从球距侧面再次取消追逐；钩位实际离开该固定追饵球仍会取消。鱼继续以现有速度追踪实时钩位，确认咬钩仍要求鱼嘴进入原有 0.08 m 接触距离。单钩和 Sabiki 分别在 `:2321`、`:1763` 调用同一校验规则。

## 最近一次追逐记录与 F3

`_last_pursuit_result_snapshot` 保存最近一次结束结果（`scripts/boat_fishing_casting_system.gd:213`）。成功确认、超时、范围离开、钩位失效、pending/School 无效、Authority 取消和确认拒绝等结束路径写入同一记录结构（`:2115`、`:2167`、`:2191`）。记录包含鱼种、School/catch ID、钩位、触发来源、结果和原因、持续时间、鱼嘴至钩距离、钩深、School 活动深度/状态、追饵半径、钩至初始球心距离、pending 释放结果及权威线长。

记录在候选重采样和新追逐开始时保留，只在下一次追逐结束时覆盖；船钓活动结束时清除（`:333`）。单钩结束标记及 Sabiki 每钩结束标记避免重复回调覆盖同一次结果。Authority 的取消原因直接写入结果（`:3351`）；pending 状态分别显示 `confirmed`、`released`、`released_by_authority` 或 `not_released`，未确认的释放不会显示为成功。

F3 Fishing 的 Boat School Targeting 区域新增独立的 “Last Pursuit Result” 项（`scripts/fishing_debug_panel.gd:124`、`:1409`），与进行中的追逐诊断分开。鱼种名、成功/失败、触发来源、结束原因、钩位、距离、深度、School 状态和 pending 结果通过 `resources/translations/fish_species.csv:960` 起的新增条目提供英文与简体中文。普通 HUD 未增加诊断内容。

## 定向测试

新增 `tests/test_p6_4_5_4b_pursuit_lifecycle.gd`，基于主场景、真实本地 Authority 和 16 FPS 更新运行完整状态机。结果：`failures=0`。

| 场景 | 修复前 | 修复后 |
|---|---|---|
| 固定深度、海鳟约 9 m | P6.4.5.4a 受控复现为 11.312 s 接触 | P6.4.5.4 独立回归仍通过：资格/追逐成立，鱼嘴接触距离 0.067 m；本轮无固定深度资格改动 |
| 追逐中鱼群下潜 | 6.688 s 时因 `activity_depth_mismatch` 取消，鱼嘴距钩 3.342 m | 完整状态机继续追逐；School 代表深度变化 5.356 m 后，11.312 s 到达 0.0459 m 并确认，最终进入 FIGHTING |
| 钩位离开追饵球 | 应取消 | 共享存活校验返回 `pursuit_range_exited`；半径未改 |
| pending / School 失效 | 应取消 | stale/missing pending 返回 `pending_catch_invalid`；不可用 School 返回 `school_unavailable` |
| 超时 | 应取消并释放预约 | 通过状态机触发 `approach_timeout`，返回 WAITING，记录 `released_by_authority`；鱼群人口未提前扣减 |

测试另验证：候选采样及新追逐开始不会清除最近结果；Authority 外部取消的原始原因 `test_authority_external_cancel` 会被保留，释放结果显示 `released_by_authority`；Sabiki 使用同一深度无关的追逐校验并记录正确钩位。Sabiki 多钩闭环中新增的最近追逐记录断言也通过。

运行的检查：

- `godot --headless --fixed-fps 16 --path . --script tests/test_p6_4_5_4b_pursuit_lifecycle.gd` — 通过，0 failures。
- `godot --headless --path . --script tests/test_p6_4_5_4_spherical_pursuit.gd` — 通过，0 failures。
- `godot --headless --fixed-fps 16 --path . --script tests/test_p6_3_1_single_jig.gd` — 通过，0 failures。
- `godot --headless --fixed-fps 16 --path . --script tests/test_p6_3_2_sabiki_multi_catch.gd` — 通过，0 failures；包含最近追逐钩位记录断言。
- Godot headless editor/import 检查 — 脚本导入成功，无本次修改导致的解析错误。
- `git diff --check` — 通过。

Godot headless 退出时报告一个 Dummy Renderer shader RID 泄漏；测试进程退出码为 0，测试断言全部通过。该提示不代表 GPU 画面已验证。

## 文件与边界

本阶段修改：

- `scripts/boat_fishing_casting_system.gd`
- `scripts/fishing_debug_panel.gd`
- `resources/translations/fish_species.csv` 及导入生成的英文、简体中文翻译资源
- `tests/test_p6_4_5_4b_pursuit_lifecycle.gd`（含 Godot 生成的 UID）
- `tests/test_p6_3_2_sabiki_multi_catch.gd`（增加最近结果钩位断言）

未修改 `FishingEncounterSystem` 的候选资格、预约或结算实现，也未修改 Authority 人口、追逐参数、搏鱼、Ambient 或拖钓路径。GPU Mac 实机验证尚未执行；headless 状态机测试不能替代实机画面验收。
