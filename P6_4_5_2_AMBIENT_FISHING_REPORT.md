# P6.4.5.2 — 普通海域随机垂钓与 Authority 自然鱼生成报告

## 结果概述

船钓空钩现在有两条互斥的自然中鱼来源：有效真实鱼群继续走 `SCHOOL_TARGETED`；没有合格定向鱼群且 Authority 能为实际钩位找到合法鱼种时，使用整副钓组共享的现实时间 `AMBIENT_ENCOUNTER` hazard。Ambient hazard 触发后才由 `FishLocalAuthority` 注册一条临时自然鱼，鱼种和体长取自现有鱼种配置，之后沿用既有接近、确认中钩、搏鱼和收获事件流程。

Ambient 个体没有伪造的 `school_id`，不从附近无关鱼群扣人口。普通海域也不需要 50 m 内存在真实鱼群。15 m 首次落水搜索仅用于候选诊断，不锁定本次抛投的鱼源。

## 文件修改

- `scripts/fish_authority_adapter.gd`：定义临时自然鱼候选、请求、查询、确认、释放及单条/批次结算接口。
- `scripts/fish_local_authority.gd`：复用鱼种生态配置、钓组兼容数据与测深，筛选并登记临时自然个体；为混合 Sabiki 批次增加先验证后提交的 Authority 事务。
- `scripts/fish_resource_manager.gd`：将新增 Authority 操作转发给唯一 Local Authority，并同步资源版本。
- `scripts/fishing_encounter_system.gd`：维护船钓/抛投会话、首次落水诊断、目标/偶遇优先级、共享 hazard、PendingCatch 来源、取消与单条/批次结算。
- `scripts/boat_fishing_casting_system.gd`：从实际亮片/钩位位置采样；串钩按空钩分别检查定向候选，但共享一个 ambient hazard；触发后使用原有咬钩和搏鱼入口。
- `scripts/fishing_pending_catch.gd`、`scripts/fishing_catch_result.gd`：保留 `source_type` 与 `ambient_fish_id`，让 Pending 与最终结果带有来源身份。
- `scripts/fishing_debug_panel.gd` 和 `resources/translations/fish_species.csv`、`fish_species.en.translation`、`fish_species.zh_CN.translation`：增加中英文首次落水、hazard、Authority 结果和临时鱼诊断。
- `tests/test_p6_4_5_2_ambient_fishing.gd`：新增 Authority、Hazard、生命周期及真实主场景 headless 流程测试。
- `tests/test_p6_4_5_1_boat_fishing_bite_rework.gd`、`tests/test_p6_3_2_sabiki_multi_catch.gd`、`tests/test_p6_3_3_bite_experience.gd`：更新仍假定“偶遇必须来自附近鱼群”或“每个串钩各自叠加 hazard”的回归测试夹具。

## 首次落水与会话

`BoatFishingCastingSystem._record_boat_fishing_first_entry()` 在亮片第一次有效入水、或 Sabiki 钓组完全入水/铅坠到底时记录世界位置（`scripts/boat_fishing_casting_system.gd:3103`）。单钩取实际钩尖位置；Sabiki 的首次搜索位置取各钩位的平均位置。该坐标传给 `FishingEncounterSystem.begin_boat_fishing_cast_session()`（`scripts/fishing_encounter_system.gd:319`），用 15 m 半径查询仅作为首次落水诊断，并保存 School ID 列表（`scripts/fishing_encounter_system.gd:322-340`）。

后续定向判定仍以每个实际钩位的世界位置和深度重新查询；Sabiki 首次落水位置不会锁定后续钓鱼模式，也不会取代钩位坐标。

## 两种来源的优先级与切换

在 `evaluate_boat_fishing_candidates()` 中，真实 Authority 鱼群候选继续使用既有 50 m 水平候选范围，并计算鱼群三维活动范围、鱼种/钓组兼容、水层、动作及人口可用性。只有没有可定向中鱼候选、且钩位没有落在一个会阻断 ambient 绕过资格的真实鱼群范围内时，才向 Authority 请求普通海域候选（`scripts/fishing_encounter_system.gd:491-504`）。

- 合格真实鱼群优先使用既有 `SCHOOL_TARGETED` 反应；核心区 2–5 秒、边缘 5–10 秒参数未改。
- 钩位进入真实鱼群的三维范围、但鱼饵/深度/动作/资源资格不满足时，该鱼群会阻断 ambient 生成，防止错误钓组通过随机生成绕过失败条件。
- 定向候选或已开始的接近会从共享 hazard 的可选空钩中排除。进入定向区会清除已累计的 ambient hazard，避免两种模式同时累计（`scripts/fishing_encounter_system.gd:752-834`）。
- Sabiki 的每个空钩独立使用真实坐标评估目标鱼群与 ambient 候选。已挂鱼、正在接近、被锁定的钩位不参与新的 ambient 选择；其他空钩仍可参与。
- 单钩活动期间 Encounter 状态、抛投会话 ID 和钩位状态防止同钩重复请求；Authority 请求也拒绝会话中同一钩位已有 `reserved` 或 `hooked` 临时鱼（`scripts/fishing_encounter_system.gd:1012-1028`、`scripts/fish_local_authority.gd:207-216`）。

## Ambient Hazard 与默认参数

配置集中在 `FishingEncounterSystem`：基础 2 次/现实小时、每副钓组上限 3 次/现实小时、物种丰富度修正上限 1.25（`scripts/fishing_encounter_system.gd` 的 Boat Fishing balance 导出项）。Hazard 使用指数阈值 `E = -ln(U)`，每个有效检查周期按实际经过时间累计：

```text
λ_hook = 2.0 × environment_quality × min(1.25, 1 + 0.10 × log2(该钩位不同合格鱼种数))
λ_tackle = min(3.0, 所有当前合格空钩的 λ_hook 最大值)
H += λ_tackle × dt_real / 3600
H >= E 时触发一次偶遇，然后重新抽取阈值
```

因此 Sabiki 钩位不会把 2 次/小时基础率乘以钩数；钩位数仅影响触发时可供选择的合法空钩。以单一合格鱼种、环境质量 1 为例，λ=2/h，指数分布平均等待 30 分钟；适宜且有多个兼容鱼种的水域可由丰富度修正提高事件率，理论最高为 2.5/h（平均 24 分钟，另有 3/h 的安全总上限）。环境和动作质量低会降低事件率；没有合法候选鱼种时事件率为零。每次检查由 `BoatFishingCastingSystem._update_natural_bite_judgement()` 以真实 delta 低频采样（`scripts/boat_fishing_casting_system.gd:1316-1327`），不按每帧概率抽签，也不使用加速游戏时间。

触发时从当前合格空钩中按该钩位候选生态权重选择一个，再让 Authority 重新确认鱼种资格。单钩的默认 2/h 目标意味着平均等待约 30 分钟，不是固定 CD、倒计时或保证发生的时间。

## Authority 候选、个体和生命周期

`FishLocalAuthority.evaluate_ambient_fishing_candidates()`（`scripts/fish_local_authority.gd:123-202`）仅评估传入的真实钩位，采样该处海底深度，使用当前动态海面传入的水柱与钩位真实深度。它依次要求：鱼种支持 `boat_fishing`、当前钓组兼容、动作资格满足、最低水柱足够、海底栖息地适配、鱼种活动水层与钩位深度匹配，以及生态权重大于零。若鱼种已有海草生态参数，也复用其现有位置权重。鱼种按现有 `spawn_chance × habitat × activity_depth × vegetation × relative_bite_tendency` 权重抽取（`scripts/fish_local_authority.gd:144-192,372-430`）。没有从全游戏鱼种表无条件抽鱼。

只有 hazard 触发后，`request_ambient_fish_encounter()` 才创建单条记录（`scripts/fish_local_authority.gd:207-264`）：生成独立 ambient ID、按原鱼种体长范围生成一次体长、记录 species、session/cast、hook、实际深度、出生位置、栖息地和 `source_type=ambient`。不生成常驻 3D 鱼群、不创建 School ID、不改真实 School 人口。该记录依序经历 `reserved → hooked → settled`，取消则释放；重复结算被 settled ID 拒绝（`scripts/fish_local_authority.gd:267-314`）。

单钩先把 Authority 个体映射成 `FishingPendingCatch`，然后使用已有 `_begin_bite_event()` 和 `confirm_boat_fishing_bite()`；浅水仍走原接近表现，HOOKED 后仍进入 P6.4.4/4.5 搏鱼与 landing。单钩结算消耗临时 Authority 记录并发出既有 `FishingCatchResult` 信号，不扣学校人口（`scripts/fishing_encounter_system.gd:1228-1254,1280-1350`）。Sabiki 每钩独立保留 pending/鱼身份，最终批次可以混合 School 与 Ambient 捕获；Authority 先整体验证学校减量和 ambient ID，再一次性提交（`scripts/fishing_encounter_system.gd:1353-1443`、`scripts/fish_local_authority.gd:317-363`）。

取消、离水、断线、退出活动或场景清理会释放未结算临时记录；成功结算后记录被移除并进入防重复集合。Ambient 捕获来源和 ID 通过正常结果事件保留。当前 `FishingCatchResult` 注释说明这是会话级结果，现有项目的实际渔获呈现由既有 `catch_succeeded`/批次信号和 HUD 消费；本次没有另建或扩展库存系统。

## F3 诊断

Fishing Debug 在已有中鱼诊断刷新中显示：session/cast ID、当前累计 hazard 与随机阈值、首次落水坐标/15 m 半径/候选学校、ambient 事件率/平均统计等待/合格鱼种数、最近 Authority 请求结果，以及临时鱼 ID、species、体长、钩位与生命周期（`scripts/fishing_debug_panel.gd:902-955`）。每个 Sabiki 空钩仍有自己的位置、深度和状态行。F3 关闭时没有新增逐帧全 Authority 扫描；诊断查询沿用现有面板请求时机。

## 定向案例

### 案例 A：附近没有真实鱼群

测试在有效海底且没有 50 m 内真实鱼群的位置，Authority 返回兼容钓组的自然鱼种。Sabiki 的 Local Authority 测试明确得到 Herring 候选、合法体长、唯一 ambient ID，执行 reserve→hooked→settled 后所有学校总人口不变。另一个实际 Main 场景 headless 测试找到 Single Jig 兼容水域，强制测试阈值触发后走现有 `BITE_APPROACH → FIGHTING → landing → catch_succeeded`，并确认 Authority 记录清理、School 总量不变。测试阈值只在测试脚本中设置，不改正式概率。

参数计算例：一个合法候选、`environment_quality=1`，λ=2/h，平均等待 1800 秒；在 10 分钟内触发概率约 `1-exp(-2×600/3600)=28.3%`。实际具体海域的 λ 会由 Authority 环境质量修正，不保证每个 30 分钟窗口必有鱼。

### 案例 B：真实鱼群核心

回归测试将钩位放在兼容鲱鱼群的真实三维目标区，得到 `SCHOOL_TARGETED`，ambient candidates 为空；已有累计 ambient hazard 被清零。该路径保留 2–5 秒核心反应逻辑，不应用普通海域 hazard。

### 案例 C：部分 Sabiki 钩位定向、其他空钩可偶遇

串钩测试使用 5 个实际钩位评估，确认目标/接近钩被排除后其余 4 个空钩仍参加共享 hazard。单钩输入与五钩输入在相同候选环境下具有相同事件率和 900 秒 hazard 增量，未乘 5。另有混合结算测试确认一条 School 鱼和一条 Ambient 鱼在一次 Authority batch 中各处理一次、学校人口只减 1、两种来源均保留。

## 测试结果

以下 Godot 定向脚本均退出码 0，结果为 `failures=0`：

- `tests/test_p6_4_5_2_ambient_fishing.gd`：Authority 候选/临时身份/释放和重复结算、无近邻学校、模式优先级、错误鱼饵阻断、共享 Sabiki hazard、混合批结算，以及实际 `main.tscn` headless ambient bite→fight→landing。
- `tests/test_p6_4_5_1_boat_fishing_bite_rework.gd`：定向鱼群与反应时间回归。
- `tests/test_p6_3_1_single_jig.gd`、`tests/test_p6_3_2_sabiki_multi_catch.gd`、`tests/test_p6_3_3_bite_experience.gd`。
- `tests/test_p6_4_2_boat_fishing_fight_model.gd`、`tests/test_p6_4_3_boat_fishing_fight_solver.gd`。
- `tests/test_fishing_p3.gd`、`tests/test_fishing_p3_2.gd`：最小拖钓回归。
- `godot --headless --editor --path . --quit` 项目脚本导入检查，以及 `git diff --check`。

Headless Godot 退出时出现一条 RendererDummy shader RID allocation leak 提示，但所有上述脚本均以 0 失败退出。该提示不是 GPU 视觉验证结果。

## GPU 验收与已知限制

本轮没有运行 GPU 图形场景，不能宣称已验证实际鱼模型画面、声音、F3 排版或船边表现。上面的真实主场景测试由 Headless renderer 执行，仅验证逻辑与 Authority 生命周期。

临时 ambient 个体是“hazard 后生成、捕获或取消后清理”的 Authority 记录，不是常驻生态人口，也没有地区级可捕获数量账本；长时间反复垂钓可以持续在事件发生时生成新个体。这符合本阶段不新建区域人口系统的范围，但未来若要让普通海域鱼量被实际捕捞消耗，需要 Authority 增加独立生态库存或恢复模型。`source_type=ambient` 已保留在 CatchResult 以便该扩展。

第一次 15 m 搜索只用于诊断，不是实际中鱼半径；定向鱼群仍使用原 50 m 候选预筛。Ambient Hazard 的 2/h 与 3/h 参数尚未经过长时间玩家手感平衡，也不是玩家期望保证的 20–40 分钟固定出鱼时间。可视不可视鱼群的实机定向验证问题没有在此轮调范围或概率；不可视目标鱼群仍须另行进行 GPU 验收。

## 最简人工验收步骤

1. 用 GPU 构建启动游戏，进入船钓并选择 Single Jig。
2. 找一片 F3 显示 50 m 内无真实 school 的有效水域，下钩并保持鱼饵处于 Authority 接受的深度/动作条件；F3 应显示 `AMBIENT_ENCOUNTER`、非零 hazard rate 和阈值累计。正式事件按概率等待，不用测试按钮改正式概率。
3. 找到可视鱼群并将钩位置于其合格三维范围；F3 应显示 `SCHOOL_TARGETED`，没有 ambient 来源抢占，并沿现有咬钩、搏鱼和结算完成。
4. Sabiki 下钩时观察各钩位状态；空钩参与共享 ambient hazard，已有目标鱼群/预约的钩位不重复生成事件。
