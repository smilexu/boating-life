# P6.4.5.3.2a.1 — 全鱼种船体经过时的鱼群视觉异常专项诊断

## 结论

**这是 `FishSchoolRenderer` 对三种表层远洋鱼共用的局部实例剔除问题，不是鲱鱼模型独有问题。**当前注册的鲱鱼、海鳟和针鱼都走同一个 5 米船周排除条件，三者在该水平圆区内的个体会从渲染记录中省略。排除与 Authority 的 CALM / ALERT / FLEEING 状态无关，因而即使 Authority 正在正常累积惊扰，Renderer 仍会先把船周的鱼直接抹掉。

代码还会把被省略的实例从 MultiMesh 活跃列表中移除，并清掉其个体视觉状态。船移开后，同一稳定个体 key 会从 school seed 确定性重建，所以会回到初始队形附近。这与“空白区域跟着船走、船离开后原位重新出现”的描述高度吻合。代码路径足以确认这一具体机制；本轮没有 GPU 逐像素取证，因此不把画面中每个消失实例都归因于它，也未验证水面/船体遮挡贡献。

三刺鱼走底栖专用分支：通常只有 0.65 米船周排除，进入 FLEEING 时该排除关闭。因此它**不是同等范围的公共异常**，但仍有一个小型非逃散时的 Renderer 裁切圈；其 GPU 观感尚未实机确认。

本轮没有修改正式游戏代码、鱼种参数、测试文件或 Authority 行为。新增本报告，并运行现有的两项定向 Headless 检查。

## 鱼种注册与视觉行为矩阵

主场景没有覆盖 `species_profiles`。`FishResourceManager._load_default_profiles()` 实际装入 `resources/fish_species/` 下的四个 Profile（`scripts/fish_resource_manager.gd:73–83,475–485`; `scenes/main.tscn:311–319`）。鱼群 Renderer 为每个 Profile 建立一个 `MultiMeshInstance3D`，各用其配置模型；底栖三刺鱼另用身体色调材质参数（`scripts/fish_school_renderer.gd:459–529`）。当前没有其它 `FishSpeciesProfile` 资源接入这个 Renderer；海豚由独立系统管理，不计入本矩阵。

| Species ID | 活动类型与 Renderer 行为 | CALM / ALERT / FLEEING | 船体影响与可见路径 | 特殊分支 / 风险 |
|---|---|---|---|---|
| `herring` | 中层生态鱼；`schooling_pelagic`；表层活动周期开启；模型 `herring.glb`（`resources/fish_species/herring.tres:7–30`） | 读 Authority 三态，映射到既有 `cruising/schooling`、`alert`、`scattering/flee`，之后 `recovering/regrouping`（Renderer `:850–860,901–981`） | 与其它非底栖鱼共用 `boat_exclusion_radius_m=5m` 的水平剔除；表层活动深度超过 6m 逻辑阈值时整群转为逻辑态（`Renderer:20,576–589,1195–1199`） | 队形半径默认约 2.4m，小于 5m 排除圈；鱼群大部分或全部进入圈内时最容易呈现“橡皮擦”。已由玩家观察到此异常；GPU 根因仍待对照取证。 |
| `sea_trout` | 表层生态鱼；`fast_pelagic`；表层活动周期开启；模型 `seetrout.glb`（`resources/fish_species/sea_trout.tres:7–30`） | 同一 Authority 三态和表层活动分支；`fast_pelagic` 在恢复阶段额外向 formation anchor 回游（Renderer `:950–981,1076–1086`） | 同一 5m 船周剔除；6m 逻辑深度阈值与迟滞同上 | 配置队形半径 5.2m，普通状态下 5m 圈会移除大部分中心区域个体；散开时外围鱼可以仍显示。与鲱鱼共用风险路径，但未有玩家 GPU 观察记录。 |
| `needlefish` | 表层生态鱼；`fast_pelagic`；表层活动周期开启；模型 `needlefish.glb`、模型前向轴与前两者不同（`resources/fish_species/needlefish.tres:7–30`） | 与海鳟共用 `fast_pelagic` / 表层三态路径 | 同一 5m 船周剔除；表层 6m 逻辑阈值同上 | 模型轴、游速、敏感度不同，但剔除发生在模型朝向与材质之前，所以不会规避该问题。配置队形半径 5.2m；共用风险、尚未 GPU 实测。 |
| `three_spined_stickleback` | 浅水底栖；`coastal_benthic`；未启用表层活动周期；模型 `three_spined_stickleback.glb`（`resources/fish_species/three_spined_stickleback.tres:7–27`） | Authority 三态进入底栖专用行为；含底栖深度目标、海床边缘转向、邻鱼收拢/散开和恢复（Renderer `:904–949,1014–1075,1087–1093`） | 非 FLEEING 时水平排除半径 0.65m；FLEEING 或 F3 水下观察时设为 0（Renderer `:1195–1199`）。不走表层 6m 整群隐藏门槛。 | 专用邻居网格、海床约束及身体色调材质；不具备 5m 圈的大范围“橡皮擦”风险，但非 FLEEING 时仍可能出现极近船的小空隙。Headless 已测到船正上方观测会关闭该小排除；未作 GPU 船体遮挡验收。 |

三个表层鱼的 Authority 敏感度分别为 Herring 1.00、Sea Trout 1.20、Needlefish 0.85；三刺鱼使用 Profile 默认 1.00（`fish_species_profile.gd:45`; 各 `.tres`）。敏感度只缩放 Authority 惊扰目标，不改变 Renderer 的 5m 排除条件。

## 异常路径与分类

### 直接原因：实例被 Renderer 主动剔除并重建

1. `_build_school_fish()` 先根据 Authority 状态推进局部鱼群运动和队形半径（`scripts/fish_school_renderer.gd:850–860,1014–1142`）。
2. 对非 `coastal_benthic` 鱼，`boat_clearance` 取 Inspector 默认值 5.0m；接下来仅按鱼位置到船中心的 XZ 距离判断，小于半径即 `continue`（Renderer `:1194–1199`）。该判断不看水深、船速、是否 FLEEING，也不等待鱼游出。
3. 被 `continue` 的鱼没有加入当前 `fish_records`。外层按记录数设置 `MultiMesh.instance_count` 和 `visible_instance_count`（Renderer `:630–649`），随后把没有活动记录的 key 从 `_individual_states` 删除（`:650–652`）。因此它既不是透明度变低，也不是只被 GPU 遮挡：这个实例确实从提交给 MultiMesh 的可见实例集中移除了。
4. 船移开后，`_build_school_fish()` 因 key 不存在而重新调用 `_create_individual_state()`；该函数以 school seed、个体序号和 species index 派生 RNG（Renderer `:875–880,1301–1354`），个体从确定性的初始队形附近再次出现。船留在附近时，实例在每个移动 tick 中会被再次剔除、清理和初始化，故其运动状态无法连续保留。

鱼身没有通过缩放到零或 alpha 渐隐而消失：实例的正尺寸由 `visual_length_m / 1.2` 生成（Renderer `:1203–1216`）；`shaders/fish_swim.gdshader` 只做尾部顶点摆动和色调计算，没有透明度输出。现有其他 `continue` 还会因鱼群进入深层逻辑态、局部水深不足或最小水柱不满足而隐藏个体/整群（Renderer `:579–589,1152–1172`），但它们不是一个随船移动的 5m 水平空洞。

### Authority 和 Renderer 的实际职责

Authority 在 `FishResourceManager._process()` 中更新，并调用 `_update_authoritative_disturbance()` 采集船速、发动机状态、船底高度和附近 School 样本（`scripts/fish_resource_manager.gd:100–114,116–178`）。`FishLocalAuthority.update_school_disturbance()` 按水平距、鱼群在船底下的深度、船扰动和鱼种敏感度计算目标，再更新惊扰 level/state（`scripts/fish_local_authority.gd:131–195`）。状态保存在 `FishSchoolState`（`scripts/fish_school_state.gd:32–41`）。这里没有发现状态之外的鱼群删除或人口扣减。

Renderer 读取快照的 `disturbance_state` / `disturbance_level` 并选择视觉分支（`:856–860`）。船的实时方向/速度只在 Authority 已经处于非 CALM 后被整理成逃离方向输入（`:_authoritative_escape_sources`，`:838–847`）；它不单独设置另一个惊扰三态。局部 `scattering`、`recovering` 是状态映射和恢复呈现阶段，不是第二个 Authority。水面鱼确有连续逃散加速度和扩散半径目标（`:1076–1086,1121–1138`），底栖鱼另有海床/邻居路径（`:1066–1093`）。这些位移在 Renderer 内作为 `school_anchor + local_offset` 生成，未写回 Authority 锚点。

但在非底栖鱼中，5m 排除条件发生在逃散运动计算之后、记录提交之前，而且没有 FLEEING 豁免；逃散代码不能阻止鱼进入空白区，也无法让被删除的个体状态持续积累位移。换句话说，Authority 可以正常进入 ALERT/FLEEING，Renderer 也会计算逃散，但船体附近的最终输出仍被清掉。**局部空洞不应解释为 Authority 没有惊扰或鱼群正常逃离。**

## 半径、深度、LOD 与状态切换检查

- 表层鱼的个体水平活动限幅为 `_school_wander_radius(profile) + visual scatter expansion`；Herring 默认约 2.4m，海鳟/针鱼配置为 5.2m。底栖三刺鱼取 `max(school_wander_radius_m, school_activity_radius_m)`，配置活动半径 2.8m（`FishSpeciesProfile` 默认与鱼种资源；Renderer `:1120–1142,1374–1375`）。局部限幅确实可能把越界位移夹回边界，但不是船周空洞随船平移的起因。
- P6.4.5.3.2a 增加的 `visual_scatter_radius_response_mps=2.5` 作用于每条鱼的视觉扩散半径 envelope，再进行已有活动半径约束（Renderer `:28,1121–1139`）。它覆盖四类行为路径中的散开/恢复半径更新，但不控制船周 `boat_clearance`。它不能修复本次发现的剔除/状态清理。
- Renderer 的主要逻辑/视觉 LOD 是表层活动深度门槛。已有可见 School 在深度高于 threshold+0.35m 后退出视觉列表；不可见 School 在低于 threshold−0.35m 前不重新进入（Renderer `:576–589`）。该整群切换带迟滞，不跟随船的 XZ 圆圈。项目配置的三个表层鱼阈值为 6m；三刺鱼不使用该分支。
- MultiMesh 是按物种批次，没有发现每鱼种独立的透明/隐藏材质分支。底栖鱼只额外有身体色调 shader 配置。渲染预算和每种实例上限会造成远处学校或超预算个体不绘制，但选择顺序以距船由近到远优先（Renderer `:532–549,593–603`），与“船下出现固定半径洞、船走后消失”不同。
- 同一 School 中的队形半径、Boat clearance 和海床限幅是渲染局部规则；它们不影响 Authority 的 School `world_position`。FishingEncounter 与 Fish Finder 读取 Authority 学校锚点/活动信息，而不是这些被渲染剔除的实例（`scripts/fishing_encounter_system.gd:380–425`; `scripts/fish_finder_sensor.gd:170–181,210–247`）。所以本次 Renderer 剔除不等于真实鱼群瞬移或 Authority 将人口删除。

## 其它潜在原因：尚不能由本轮代码检查判定画面贡献

1. **水面/船体遮挡**：近水面鱼可能被船体网格、深度缓冲或水面透明排序遮住。Headless 无法判定画面像素是否由遮挡贡献。无论遮挡如何，代码已经确定会在 5m 圈内主动移除这三种表层鱼的实例，因此至少有一项明确的 CPU 侧剔除。
2. **状态相关的真实视觉位移**：如果 Authority 进入 FLEEING，鱼会依配置加速并外散；深度活动也可能随鱼种状态变化。此类移动来自 Renderer 转换后的位置，并不应表现为船中心固定空洞。Headless 既有测试验证了三刺鱼的状态映射和位置变化，不等于验证了三个表层模型的 GPU 像素。
3. **深度 LOD**：水面鱼群下潜超过逻辑阈值会整体暂时不渲染。它需要通过同一 School 的 `activity_depth_m` 和 `_school_render_states` 记录来排除；不符合“空洞跟船移动”的空间特征。

## 验证证据与边界

本轮运行：

- `godot --headless --path . --script tests/test_fish_resources.gd` — 退出码 0，`failures=0`。确认四个 Profile 可加载；Authority ALERT/FLEEING 和恢复行为通过；三刺鱼在 F3 水下观察期间不被船中心局部规则裁掉。测试未记录 Herring/Sea Trout/Needlefish 穿越 5m 船周圈时的每帧 MultiMesh 数量，也没有 GPU 输出。
- `godot --headless --path . --script tests/test_p6_4_5_3_1_school_disturbance.gd` — 退出码 0，`failures=0`。Authority 三维扰动及三态计算通过；不验证 Renderer 可见像素。
- `git diff --check` — 通过。

Headless 结果支持状态逻辑、变换更新代码和鱼种资源存在性；不支持水面遮挡、GPU 裁剪、材质排序等结论。**没有完成 GPU 实机取证，也没有在 Headless 逐鱼追踪 3 种表层鱼的 MultiMesh 可见实例序列。**这不影响从 `continue → records 减少 → instance_count/visible_instance_count 减少 → 个体状态清理` 的静态代码链确定 5m 公共剔除规则存在。

## 最小修复建议（本轮未实施）

下一步最小修改应优先集中在 `FishSchoolRenderer._build_school_fish()` 的 `boat_clearance` / `continue` 路径（`scripts/fish_school_renderer.gd:1195–1199`）：不要因进入船心 5m 圆区就从物种记录里删除鱼并遗忘个体状态。若出于船体遮挡需要隐藏，应保留 Authority/个体运动状态和可见实例的数据流，采用船型/深度相关的可视遮挡或可持续的避让运动作为独立方案；不要把当前客户端可见性过滤解释成鱼已逃离。任何改动需另行检查船体外形与近水面水面深度，并以 GPU 实机观察确认。

**是否某些鱼种需要独立修复：**代码层面，Herring/Sea Trout/Needlefish 共用同一个 5m 排除缺口，无需分别改模型；队形半径和样式造成视觉幅度不同。三刺鱼分支不同，只存在 0.65m 小排除，需要单独实机确认是否可见，并不支持按同一 5m 根因处理。没有证据要求对模型、材质或 LOD 各做一套独立修复。

## 最小 GPU 实机取证步骤

在 Mac 或 Windows 同一机位/海况下分别选择 Herring、Sea Trout、Needlefish 的浅层 School；用 F3 记录 school ID、Authority state、boat XZ、school anchor、Renderer `visualized_fish`/`visible_fish`。相机保持水下斜视，关闭 F3 面板遮挡后，让船以停机/低速经过学校中心，再离开至少 7m。对比中心进入 5m 前、圈内和离开后的可见实例数及固定个体的 `visual_to_transform.origin`：若实例数随进入圆圈下降、离开后上升且个体 key 重建，则直接验证 CPU 剔除；若 instance 数稳定但像素消失，应继续单独检查船体/水面遮挡。三刺鱼重复同样步骤，重点区分 CALM（0.65m）与 FLEEING（clearance=0）的视觉效果。该步骤是后续取证建议，不是本轮已完成的 GPU 测试。
