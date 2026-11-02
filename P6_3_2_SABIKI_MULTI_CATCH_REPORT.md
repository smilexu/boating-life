# P6.3.2 — 串钩多鱼收获与 50 米判定报告

## 修改内容

- `scripts/boat_fishing_casting_system.gd`：为每个串钩钩位维护独立的空钩、接近、预留和挂鱼状态。自然中鱼逐钩使用真实钩位坐标与动态海面深度查询；已挂鱼或正在接近的钩位不再判定。第一条鱼挂钩后留在 `SABIKI_HOOKED_WAITING`，空钩继续等待。HUD 的“收获串钩”按钮可主动开始收线；所有可用钩位挂满时自动开始收线。
- `scripts/fishing_encounter_system.gd`：沿用共享鱼群 Authority 和 P3 自动收鱼，只为本批次建立一个自动搏鱼流程。Encounter 内的挂钩预留账本从各候选鱼群的可用数量中扣除已预留数量，阻止串钩过量预留；取消时释放。成功收回后发出每条鱼独立的结果和一次 `sabiki_batch_settled` 批次事件。
- `scripts/fish_local_authority.gd`、`scripts/fish_resource_manager.gd`、`scripts/fish_authority_adapter.gd`：增加本地 Authority 原子批量扣减接口。先验证所有鱼群及数量，再一次性提交；资源不足时整批拒绝，不产生部分扣减。
- `scripts/fishing_pending_catch.gd`、`scripts/fishing_catch_result.gd`：结果携带钓组、钩位、批次 ID、批次数量和调试标记。每条鱼保留独立长度与估算重量。
- `resources/fish_species/herring.tres`：只将鲱鱼的支持钓法增加为 `boat_fishing`；未添加拖钓支持。现有 Sabiki 配置已包含鲱鱼白名单和五个钩位，本轮未改串钩资源或视觉顺序。
- `scripts/boat_hud.gd`、`scripts/fishing_debug_panel.gd`、`resources/translations/fish_species.csv`：显示挂鱼数、批次数量与总重量，提供主动收获入口；F3 Fishing 可指定钩位、生成下一个空钩或填满空钩。中英文已更新。
- `tests/test_p6_3_2_sabiki_multi_catch.gd`：新增距离、兼容、资源约束、批量结算、F3 和主场景流程的定向测试。

## 钓组判定与距离权重

单钩和串钩都查询以真实亮片/钩位世界坐标为中心、半径 50 m 的鱼群 Authority 数据。共用 `FishingEncounterSystem.boat_fishing_horizontal_distance_weight()`：0–10 m 为 1.0，随后按需求节点线性插值，50 m 及以外为 0。候选查询半径与权重上限共用同一常量；50 m 查询会纳入边界数据，但该点权重为零。深度匹配仍由各钩位实际深度与鱼群活动深度独立计算，水平距离不放宽水层。

事件率为：

`基础事件率 × 鱼种相对咬钩倾向 × min(sqrt(可用鱼数), 3) × 水平权重 × 水层权重 × 动作权重`

初始单钩基础率为 `1.2 / 游戏小时`，沿用 P6.3.1；Sabiki 每个空钩独立基础率为 `0.42 / 游戏小时`。Sabiki 静止动作权重为 0.8，单钩为 0.55；两者的基础率、动作范围和参考速度分别配置。每个钩位使用自己的独立指数 hazard 阈值并按实际游戏时间累计，等价于连续时间的 `p = 1 - exp(-λ Δt)`；没有将单次概率乘以五，也没有按画面帧率重复抽签。Sabiki 总事件率来自仍为空的钩位各自事件，不另乘钩数。

## 兼容性、挂鱼和批量结算

兼容性先验证鱼种允许 `boat_fishing`，再读取钓组明确的 `compatible_species_ids`；没有物种白名单时才回退到拟饵标签。因而鲱鱼仅能被现有 Sabiki 配置捕获，不会绕过钓法限制，也不会意外获得拖钓兼容性。

五钩共用串钩线和钓组运动，每钩保存独立鱼种、长度、Authority 预留记录及可视化鱼实体。浅于 6 m 时鱼从钩位附近开始游向对应钩位，到达后才确认挂鱼；深水可直接进入简化挂钩。已挂鱼跟随各自钩位，并按实际动态水面逐条触发出水表现。手动收获会取消尚未完成的接近过程，然后锁定所有已确认挂鱼；满钩自动走同一路径。自动过程复用现有 P3 收鱼和线长更新。

本地 Authority 在整批渔获资料验证后按鱼群汇总扣减，并原子提交。所有自然鱼群扣减和结果生成成功后，每条鱼生成独立 `FishingCatchResult`，再触发一次批次信号；P3 既有 `retrieval_completed` / `catch_succeeded` 只收到一个代表结果，确保自动展示与成功提示不重复。船钓 HUD 显示“成功收获 N 条鲱鱼”和总重量，`fishing_catch_success.wav` 每批播放一次。纯调试批次不改真实鱼群；混合调试与自然鱼批次只扣减自然鱼数量。取消不扣减资源并清除临时鱼。

F3 提供指定钩位、下一个空钩和填满空钩三种测试操作。它绕过自然概率与鱼群资源，但保留接近、挂钩、P3 自动收鱼和批次结果流程；重复点击被占用钩位不会生成第二条鱼。

当前项目的 `FishingCatchResult` 明确为会话级结果；没有持久渔获库存、销售或经济服务。本轮为每条鱼产生结果并更新真实鱼群资源，不虚构不存在的持久库存写入。未来非本地 Authority 需要实现原子批量扣减接口，否则会安全拒绝批次结算。

## 测试结果

- `godot --headless --path . --script res://tests/test_p6_3_2_sabiki_multi_catch.gd`：退出码 0，失败断言 0。覆盖七个距离点、25/45/50/55 m 候选、独立动作率和逐钩 hazard、资源数量上限、取消预留、自然/调试混合批次、两鱼原子扣减、F3 指定/下一个/填满、三鱼手动收获、五钩满钩自动收获、单批成功提示、移动锁恢复。
- `godot --headless --path . --script res://tests/test_p6_3_1_single_jig.gd`：退出码 0，失败断言 0，单钩自然中鱼、浅水接近、自动收鱼及调试鱼回归通过。
- `godot --headless --path . --script res://tests/test_trolling_audio_integration.gd`：退出码 0，失败断言 0。
- `godot --headless --path . --editor --quit`：脚本注册与 CSV 导入完成；`git diff --check` 通过。编辑器仍提示仓库已有的两组无关 translation UID 重复及一个 ObjectDB 退出泄漏。

Headless 主场景测试中，Godot Dummy Renderer 会输出 `Parameter "material" is null` 和一个 Dummy Shader RID 泄漏诊断；测试退出码为 0，所有断言通过。没有运行 Forward+ 图形会话，因此没有声称已通过鱼模型外观或逐条出水顺序的实际截图验收。

## 后续调校

- `sabiki_per_hook_base_event_rate_per_game_hour = 0.42`、动作权重 0.8–1.0 和水层容差仍需在正式游戏节奏中平衡；没有为便于测试而提高自然中鱼率。
- 浅水鱼接近距离、模型比例、挂钩摆动和逐条出水的视觉观感需在 Forward+ 实际画面人工复核。
- 当前批次结果和总重量是会话级展示；持久库存/销售结算需等项目建立对应服务后再接入。

## 后续修复：串钩入水折角

复查截图对应的姿态切换后，确认原因是 `_get_sabiki_up_direction_world()` 在普通等待状态将串钩主线从竿尖—铅坠方向单独旋向世界竖直方向，而外部鱼线仍从竿尖连到上眼；入水后因此在两段连接处形成折角。现在串钩在抛投、入水、等待和收线时都跟随同一竿尖—铅坠方向，外部松线弧线的末端切线也跟主线方向一致。整组离开动态水面后，旧的“收线绷紧”标记不再阻止外线下垂；钩组也按原有阻尼时间逐渐回到重力方向并摆动。钩位排列、深度和中鱼逻辑未改。

新增的七项几何断言均通过：抛投/等待/收线方向连续、上眼落在竿尖与铅坠的线段上、松弛外线与主线末端切线一致、整组出水后恢复自然下垂，且旧收线标记不能继续拉直已出水的鱼线。`godot --headless --path . --script res://tests/test_p6_3_2_sabiki_multi_catch.gd` 退出码 0、失败 0。另运行 `test_p6_2_casting.gd`，新加断言通过；该集成测试此次运行还报告 6 项其他失败（手持鼓轮投影、倾斜/出水顺序断言、出线音效状态和 F 放线速率）。由于本次修改前没有重跑该测试基线，不能确认这些失败是否原已存在。Headless 下未进行实际 Forward+ 画面验收。
