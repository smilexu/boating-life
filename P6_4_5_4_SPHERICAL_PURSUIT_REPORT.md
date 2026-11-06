# P6.4.5.4 — 球形追饵范围与鱼类主动接近报告

## 结果摘要

船钓定向鱼群资格现在按“Authority 活动中心到实际鱼钩位置的三维欧氏距离”与鱼种追饵半径比较。鱼群原有核心椭球只保留为 F3 核心范围诊断，不再拒绝椭球外、追饵球内的鱼钩。

定向接近从鱼群活动中心附近开始，以鱼种现有移动速度逐步追踪实时鱼钩位置。确认咬钩要求鱼嘴到鱼钩距离不超过 0.08 m；追逐有时间上限，鱼群失效、深度失配或钓组离开追饵球时会取消 pending catch 并清理未确认状态。

## 修改文件

- `scripts/fish_species_profile.gd`：新增可编辑的 `boat_fishing_pursuit_radius_m`，默认 12 m，Inspector 范围 1–40 m。
- `resources/fish_species/herring.tres`：追饵半径 12 m。
- `resources/fish_species/sea_trout.tres`：追饵半径 16 m。
- `resources/fish_species/needlefish.tres`：追饵半径 14 m。
- `scripts/fishing_encounter_system.gd`：以球形距离替换核心椭球的资格门槛；增加候选诊断；反应时间按追饵球内距离连续插值，并在触发快照候选中明确传递 `SCHOOL_TARGETED` 来源及钩位索引。
- `scripts/boat_fishing_casting_system.gd`：单钩与 Sabiki 定向追逐起点、限速移动、实时追踪、范围/深度有效性检查、超时取消及运行诊断。
- `scripts/fishing_debug_panel.gd`：增加追饵半径、鱼群到钩三维距离、球内/资格、接近状态、鱼嘴距离、游速与接近用时诊断。
- `resources/translations/fish_species.csv` 及中英文导入资源：增加球形追饵和接近状态双语文案，并明确旧核心椭球只是诊断信息。
- `tests/test_p6_4_5_4_spherical_pursuit.gd`：新增定向范围、移动和咬钩接触测试。
- `tests/test_p6_3_2_sabiki_multi_catch.gd`：将面板断言从旧标签名更新为当前分类面板使用的 `BoatFishingBiteOverview`。

## 空间资格与既有条件

在 `scripts/fishing_encounter_system.gd:393-427`，候选查询仍以实际鱼钩位置向 Authority 查询 50 m 水平范围内的鱼群。对每条候选，以 Authority 的 X/Z、有效活动深度和该处动态水面高度构造活动中心，再在 `:424-454` 计算 `school_center.distance_to(hook)` 并与鱼种追饵半径比较。球形半径不等于鱼群核心范围，也没有更改鱼群中心、分布、人口或鱼探仪。

旧椭球归一化距离仍在 `:420-428` 计算并通过 `inside_school_volume`、`normalized_3d_distance` 提供核心/边缘诊断；它不再参与定向资格、候选优先级或边界保持。候选结构同时保留旧值供 F3 解释核心范围。旧水平距离权重保留为诊断字段，不再决定 SCHOOL_TARGETED 资格或反应时间。候选仍必须满足鱼种支持船钓、钓组兼容、有效 Authority 人口、单钩动作资格及现有深度匹配；这些条件不因球形追饵而绕过。深度权重为零时仍拒绝，且在球内时不会转而用 Ambient 绕过该拒绝。

核心/边缘反应时间使用球内距离比例连续插值（`fishing_encounter_system.gd:887-927`），没有再增加一层空间区间。实际追逐时间由鱼群起点到鱼钩的距离除以鱼种移动速度估算；较长的实际游程会占用该反应过程，不会再叠加完整的固定接近等待。

### 找到并修复的运行时标记缺失

9 m 实际状态机测试曾显示鱼从钩边起步，接近不到 0.3 s 就确认。根因是 `_target_reaction_snapshot()` 返回的外层触发标为 `SCHOOL_TARGETED`，内部 `candidate` 却没有该字段；单钩和 Sabiki 控制器据候选字段区分定向与普通接近，于是错误地走了短距离普通路径。现在 `fishing_encounter_system.gd:959-974` 把来源和 `hook_index` 一并写入 candidate。修复后，单钩实际状态机从鱼群核心内开始限速追逐；9 m 落点测试记录到 8 m 起游，4.28 s 后才在 0.079 m 接触误差下确认。

## 主动接近与 Authority 生命周期

`boat_fishing_casting_system.gd:2047-2129` 保留原有 Authority pending catch 创建与浅水接近状态。SCHOOL_TARGETED 的鱼从活动中心朝鱼钩方向移动到鱼群核心内，偏移量不超过核心半径的 20%、1 m 或总距离的 20%（`school_pursuit_start_world`, `:3228-3238`），其余距离由实际运动完成。接近速度取鱼种现有最小/最大游速的中值。

每帧用 `advance_fish_pursuit_world()` 将鱼嘴向当前鱼钩位置最多推进 `species_speed × dt`（`:3241-3246`）；位置不通过 tween、瞬移或强制吸附到达。鱼模型使用现有鱼种嘴部锚点定位，使诊断中的鱼嘴坐标与实际钩尖目标一致。单钩接近与接触确认位于 `:2133-2181`；Sabiki 对每个钩位分别运行同一规则，见 `:1671-1750`、`:1754-1810`。

接近阶段持续验证 Authority 鱼群、物种、可用数量、活动深度及当前钩位到鱼群活动中心的球形距离（`:2011-2030`）。失效或超时会取消 pending catch；Sabiki 释放未确认的钩位预约。确认时沿用 Encounter 的现有流程：单钩创建现有 `FishingPendingCatch` 并再次验证鱼群；Sabiki 继续使用按钩位的现有 pending/reservation。鱼群人口仍在后续结算时扣减，不在追逐开始或追逐失败时扣减。没有创建新鱼群、额外鱼群个体或第二套 Authority。

AMBIENT 的 Hazard 和动画路径、P6.4.5.3.1 的惊扰倍率及拖钓流程均未在本阶段改动。定向候选仍优先于 AMBIENT；在球内但鱼饵、深度或资源条件不符时仍按原有 blocker 规则处理。

## F3 诊断

鱼钓调试视图分别显示旧核心水平/垂直尺度与核心椭球诊断，以及鱼种追饵半径、鱼群中心至钩位的三维距离、是否处于球内、最终资格、接近状态和鱼嘴至钩距离。活动追逐另显示钩位、School ID、游速和已追逐时间；Sabiki 按钩位显示。新增字段有中英文翻译。普通 HUD 未增加数值。

## 定向测试

运行环境：Godot 4.7.2；自动测试为 headless。

### 海鳟 9 m 追逐案例

专用测试通过实际 Encounter 候选评估、创建 Authority pending catch、确认咬钩前的限速运动函数和 Authority 确认步骤：

| 项目 | 结果 |
|---|---:|
| 物种 / 配置追饵半径 | Sea Trout / 16.0 m |
| 鱼群中心到鱼钩三维距离 | 9.00 m |
| 候选资格 | YES；旧椭球外、追饵球内 |
| 接近事件 | SCHOOL_TARGETED；Authority pending accepted |
| Authority 资源 | 单钩 pending 绑定真实 School ID；Authority 在开始/确认时复核可用鱼群，人口仍在结算时扣减 |
| 鱼嘴起始到钩距离 | 8.00 m |
| 鱼种游速中值 | 0.700 m/s |
| 30 FPS 模拟接近时间 | 11.33 s |
| 模拟最大速度 | 0.700 m/s |
| 确认时鱼嘴到钩误差 | 0.067 m（接触阈值 0.08 m） |
| Authority 确认 | 成功；仅在到达接触范围后确认 |

这组 Sea Trout 数据来自确定性 headless 运动模拟。另在实际单钩运行时状态机接入合法浅水 Authority 鱼群，将鱼钩放在候选中心外 9 m：本次选中 Needlefish（14 m 半径），从核心内 8 m 处起游，运行时记录 4.28 s、0.079 m 接触误差后确认，闭环断言通过。两项均为 headless 测试，不是 GPU 画面测量。

### 边界与回归

- 海鳟 9.0 m、15.9 m：在 16 m 球内；16.1 m：以 `outside_pursuit_sphere` 拒绝。
- 水平距离 0、垂直相差 17 m：按完整三维距离拒绝。
- Herring 12 m、Sea Trout 16 m、Needlefish 14 m 配置读取正确。
- 追逐函数在 30/60 FPS 下接触时间差不超过一个 30 FPS 步长；移动鱼钩时仍朝当前钩位推进且不超过速度上限。
- `test_p6_4_5_4_spherical_pursuit.gd`：通过，0 failures。
- `test_p6_4_5_1_boat_fishing_bite_rework.gd`：通过，0 failures。
- `test_p6_4_5_2_ambient_fishing.gd`：通过，0 failures。
- `test_p6_3_1_single_jig.gd`：通过，0 failures；真实场景状态机测试现在把鱼钩放在候选活动中心外 9 m，断言旧核心椭球外仍合格，并运行鱼的接近、接触确认及后续单钩闭环。
- `test_p6_3_2_sabiki_multi_catch.gd`：通过，0 failures；覆盖五钩状态、取消释放、批量收获。测试原来查询的 `BoatFishingBiteDiagnostics` 标签已由此前分类 F3 布局替换，本次把断言更新为实际存在的 `BoatFishingBiteOverview`。
- `test_fishing_p3_2.gd`：通过，拖钓回归。
- 三个主要修改 GDScript 的 `--check-only`：通过；`git diff --check`：通过。
- `godot --headless --editor --path . --quit`：退出码 0，翻译导入可读取。启动时仍报告仓库其他航行文档中的重复 UID 警告；与本次追饵文件无关。

测试退出时个别主场景脚本会尝试保存 `user://` 天气/世界时间日志，在受限测试环境产生保存告警；这不影响测试断言，但未验证这些运行时保存路径。

## GPU 验收与限制

本次未运行受控 GPU 图形场景，也没有实际游戏截图。需要人工验证 Sea Trout 鱼群中心到鱼钩约 9 m、鱼钩与活动水深匹配、使用有效 Single Jig 动作时：F3 显示 16 m 追饵球资格，鱼从鱼群附近连续游到鱼钩，鱼嘴先进入 0.08 m 接触范围再中钩；随后用 Sabiki 验证每个空钩各自追逐和预约。Headless 结果不等于视觉验收。

当前的定向鱼是一个按活动中心与核心范围偏移生成的临时视觉个体，不是 Authority 渲染器中某条具体个体的逐鱼身份/位置。运动采用直线限速追踪，转向平滑主要用于鱼体朝向；不是完整的游鱼导航 AI。追逐有效范围和垂直容差持续检查，远距离移动鱼饵可能导致追逐取消或超时，届时会释放未确认 pending。后续实机调校可以观察是否需要更合适的局部起点分布或转向路径，但不能放宽接触确认或改成瞬移。
