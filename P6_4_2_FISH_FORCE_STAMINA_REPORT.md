# P6.4.2 船钓鱼类力量、体力与挣扎模型

## 范围

本阶段新增可独立运行的船钓鱼力模型与定向测试。模型只读 `FishingPendingCatch` 的捕获身份与体长，不会移动鱼模型，也不控制船钓状态机、鱼线、渔轮、鱼竿或结算。

P6.4.1 指出的边界已保留：拖钓的 `FishingFightProfile` 仍是原有表现时间线；鱼群 Authority 和捕获记录仍由现有 Encounter 管理。`FishingPendingCatch`、`FishingFightProfile`、`FishSpeciesProfile`、`BoatFishingCastingSystem`、拖钓控制器和正式钓鱼资源均未修改。

## 修改文件

- `scripts/boat_fishing_fight_profile.gd`：Inspector 可编辑的鱼种力量与挣扎配置资源。
- `scripts/boat_fishing_fight_profile_catalog.gd`：三种首批船钓配置的轻量查找器，不是 Autoload。
- `scripts/boat_fishing_fight_participant.gd`：每条已确认船钓渔获独立持有的运行时模型与只读快照。
- `resources/boat_fishing/fight_profiles/herring.tres`
- `resources/boat_fishing/fight_profiles/sea_trout.tres`
- `resources/boat_fishing/fight_profiles/needlefish.tres`
- `tests/test_p6_4_2_boat_fishing_fight_model.gd`：本阶段纯逻辑 Godot 测试。
- 上述新脚本及测试对应的 Godot `.uid` 元数据。

关键实现位置：配置字段在 `scripts/boat_fishing_fight_profile.gd:7-47`，体型缩放和力量边界在 `:50-88`；捕获身份初始化、已确认钩鱼校验在 `scripts/boat_fishing_fight_participant.gd:39-77`，真实时间推进与快照在 `:80-122`，挣扎/力量/方向逻辑在 `:129-265`。现有鱼种体长范围分别见 `resources/fish_species/herring.tres:12`、`resources/fish_species/sea_trout.tres:12`、`resources/fish_species/needlefish.tres:12`；新平衡值位于 `resources/boat_fishing/fight_profiles/` 下对应资源。

## 配置结构与初始值

配置脚本提供基础拉力、爆发倍率/时长/间隔、体力消耗与恢复、体型参考长度/指数/倍率界限、拉力平滑时间、输出力上下限，以及只用于方向快照的游动速度提示。参数可在 Inspector 中调整；最大拉力是本模型的输出保护上限，**不是鱼线承载力或断线阈值**。

三种鱼的自然体长范围来自当前鱼种资源：鲱鱼 `0.15–0.45 m`、海鳟 `0.35–0.8 m`、针鱼 `0.25–1.0 m`。配置表中的力值以 N 表示，但都是初始游戏平衡假设，并非现实鱼类拉力的测量值，也尚未经过实机手感校准。

| 鱼种 | 基础稳态拉力 | 爆发倍率 / 下限 | 爆发时长 | 爆发起点间隔¹ | 消耗 / 恢复 | 低体力 / 恢复期倍率 | 参考体长 | 指数 / 体型范围 | 输出上限 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 鲱鱼 | 2.2 N | 2.35× / 1.12× | 0.32–0.62 s | 2.4–4.2 s | 0.26 / 0.16 每秒比例 | 0.50 / 0.45 | 0.30 m | 1.8 / 0.60–1.70 | 20 N |
| 海鳟 | 12 N | 2.8× / 1.15× | 1.35–2.6 s | 5.0–8.5 s | 0.19 / 0.075 每秒比例 | 0.42 / 0.38 | 0.575 m | 2.15 / 0.62–1.85 | 110 N |
| 针鱼 | 5.5 N | 2.55× / 1.12× | 0.50–1.05 s | 3.0–5.2 s | 0.22 / 0.12 每秒比例 | 0.48 / 0.40 | 0.625 m | 1.9 / 0.55–1.90 | 65 N |

¹ 间隔定义为一次爆发开始到下一次爆发开始的总时间，包含当前爆发时长。鲱鱼配置为短促且较频繁；海鳟配置为更强、更长并且间隔更久的冲刺；针鱼介于两者之间，爆发较快、体型影响区间较宽。

只读主动游动速度提示（稳态 / 爆发 / 恢复）分别为：鲱鱼 `0.12 / 0.72 / 0.07 m/s`、海鳟 `0.24 / 1.70 / 0.12 m/s`、针鱼 `0.20 / 1.30 / 0.10 m/s`。这些数值不直接移动鱼。

## 体型、体力与力量

体型倍率为：

```text
size_factor = clamp(pow(safe_body_length / reference_length, exponent), min_factor, max_factor)
```

长度为零、负值、NaN 或无穷大时，力量计算使用参考体长，体型倍率为 1；快照仍保留 pending catch 的原始 `body_length_m`，没有重新抽取尺寸。正常输入下，同种鱼越长，力量越大；倍率和总力均有上限。

当前体力 `s` 限制稳态力：

```text
stamina_factor = lerp(low_stamina_pull_multiplier, 1, sqrt(s))
steady_force = base_pull_n × size_factor × stamina_factor
burst_force = steady_force × lerp(minimum_burst_multiplier, burst_multiplier, sqrt(s))
recovery_force = steady_force × recovery_pull_multiplier
```

最后的输出会被配置的 `[minimum_pull_n, maximum_pull_n]` 限制。低体力会同时压低持续拉力和爆发倍率；体力跌破配置门槛时，下一轮稳态期暂不进入爆发。冲刺阶段按 `stamina_drain_rate × dt_real` 消耗体力，恢复阶段按 `stamina_recovery_rate × dt_real` 恢复，稳态阶段按恢复速率的 25% 慢慢恢复，始终夹在 `[0,1]`。

`STEADY → BURST → RECOVERY → STEADY` 是每条鱼独立的状态循环。爆发持续时间和到下一次爆发的总间隔均从该鱼自己的随机源抽取。力值通过指数响应平滑趋近状态目标，避免状态边界上出现单帧力尖峰；上升和下降分别使用 profile 中的响应时间。

## 时间与随机性

所有状态时间、体力变化和力量变化使用调用方传入的真实秒 `dt_real`，不读取世界时间倍率。participant 使用 `catch_id` 的 FNV-1a 派生默认种子，也可以传入固定 seed；每条鱼各自拥有 `RandomNumberGenerator`，不会使用全局随机序列。

`advance()` 在状态剩余时间边界处分段，并以最多 `0.05 s` 子步推进连续力量/体力变化；传入的大 `dt_real` 会一直推进到消费完，不截断或丢弃多余时间。固定 seed、固定输入方向和相同 dt 序列可复现同一状态轨迹。

## Participant 与只读接口

`BoatFishingFightParticipant.initialize_from_pending_catch()` 只接受 `fishing_method == "boat_fishing"` 且 `hook_confirmed` 的 pending catch；profile 的 `species_id` 也必须匹配。participant 初始化后不能被绑定到另一条鱼。这使它不能接收中途接近阶段的预留记录，也不能接收拖钓捕获。

`advance(dt_real, boat_outward_horizontal)` 和 `get_read_only_snapshot()` 返回独立 Dictionary 快照，字段包括 catch/hook/species/school/rig 身份、原始体长、debug 标记、随机种子、体型倍率、体力、挣扎状态与剩余时长、当前拉力 N、主动游动方向及速度提示。

快照不包含线张力、线长、收放线速度、泄力、断线、鱼竿弯曲或任何结算状态。它返回的是单鱼输入；本阶段没有多鱼主线拉力合成算法。

## 主动游动方向

初始化和状态切换时，participant 根据外部传入的船体水平外向单位向量，在外向、横向和垂直方向组合出归一化方向。方向的水平外向点积不为负，因此没有朝船的主动水平分量。若新的船体参考方向使当前方向指向内侧，会重新生成意图。无效或缺失参考方向时使用有限的 `Vector3.UP` 回退，并在快照中标记 `direction_reference_valid=false`。

方向和速度只是 P6.4.3 可读取的意图；本阶段没有鱼实体位置、碰撞、避船、提鱼点或真实移动。未来线求解器仍可以独立把鱼拉向船。

## 与 P6.4.3 的交接

1. 仅在 Encounter 确认咬钩后，用该条 pending catch 和对应 profile 创建一个 participant。
2. Sabiki 每条已确认鱼各持一个 participant，最多五个；逐条调用 `advance(dt_real, current_hull_outward_horizontal)`。
3. 求解器读取快照中的每条鱼拉力、方向和体力，并在 P6.4.3 明确决定多鱼合成方式；不要把本阶段的单鱼输出直接当作主线张力。
4. 不要从 participant 重抽体型，也不要让 participant 扣减鱼群、修改 pending catch、移动鱼实体或写入收获结果。
5. 当前 catalog 只包含 herring、sea trout 和 needlefish；遇到其他船钓鱼种时会返回 `null`。后续集成需明确添加资源或给出安全的无搏鱼/默认配置策略。

## 定向测试

运行命令：

```sh
godot --headless --path . --script res://tests/test_p6_4_2_boat_fishing_fight_model.gd
```

实际结果：退出码 `0`，报告 `failures=0`。测试覆盖：

- 三个鱼种与配置资源成功加载；使用现有自然体长范围验证体型排序。
- 非法体长安全回退，极端输出受配置上下限约束。
- 捕获身份、hook index、体长和 debug 标记保持原值；未确认咬钩记录与拖钓记录会被拒绝。
- 相同 catch/seed/dt 轨迹可复现；不同 catch ID 派生不同种子；修改返回快照不影响运行对象。
- 爆发拉力高于稳态、冲刺消耗体力、恢复阶段恢复体力、低体力降低爆发力、体力不越界。
- 五个 participant 可同时更新且首轮爆发时间不同；更新一条不会改变另一条。
- 12 秒一次推进与 240 次 0.05 秒推进结果一致；30/60 次每秒更新在相同 12 秒内的快照差异不超过 0.02；90 秒大 dt 完整跨越状态边界且输出保持有限。
- 主动方向外向点积非负；参考方向转向后不朝船；参考无效时回退为有限单位向量。

另外运行 `godot --headless --editor --path . --quit` 刷新 Godot 类注册，新增三个全局类均被识别。该项目扫描同时提示两个既有 translation UID 重复和一个退出时 ObjectDB 泄漏；这些不在本阶段修改范围内。未运行场景视觉、鱼群生态、拖钓自动收鱼或完整游戏测试，因为新模型尚未接入正式玩法。

## 未验证与后续建议

- 力值、体力消耗、挣扎频率和方向速度仅是首轮游戏平衡假设，需在 P6.4.3 张力/泄力求解器中结合明确的线承载力和拖力范围做数值调校。
- 本轮没有实机手感或视觉验收；方向快照没有驱动鱼模型。
- participant 是独立的 `RefCounted` 模型，尚未被正式中鱼、单钩搏鱼或 Sabiki 生命周期调用；拖钓行为未更改。
