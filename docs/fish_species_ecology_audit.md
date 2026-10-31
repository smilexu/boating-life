# 鱼类系统只读静态审查报告

**审查日期：**2026-10-30  
**范围：**仅检查现有代码、资源和文档；本轮未修改代码，也未运行测试。

## 1. 现有架构与数据流

主场景把鱼类管理、鱼群渲染、海豚管理和资源地图作为独立节点挂载。[main.tscn](../scenes/main.tscn#L312) 中的 `FishResourceManager` 连接本地鱼类权威、海底水深、浅海草、船只和波浪采样器，再把数据分别提供给鱼群渲染器和 F4 资源地图。

```text
main.tscn
  └─ FishResourceManager
       ├─ FishLocalAuthority ── Bathymetry / procedural seagrass
       │    └─ FishSchoolState snapshots
       ├─ FishSchoolRenderer ── client-local individual fish / MultiMesh
       └─ FishResourceMap ───── F4 map from authority snapshots
```

当前 [FishSpeciesProfile](../scripts/fish_species_profile.gd#L1) 是一个混合型 Resource：同时保存生态、模型、地图颜色和动画字段。管理器只默认加载针鱼、鲱鱼和三刺鱼三个 `.tres`；目前没有海鳟 Species 配置。[fish_resource_manager.gd](../scripts/fish_resource_manager.gd#L223) [needlefish.tres](../resources/fish_species/needlefish.tres) [herring.tres](../resources/fish_species/herring.tres) [three_spined_stickleback.tres](../resources/fish_species/three_spined_stickleback.tres)

本地权威按 700 米网格、固定世界种子生成学校；每 8 秒推进一次状态，每帧最多处理 96 个学校。种群规模、速度、部分深度和栖息地参数来自 profile，但学校生成、行为类型和部分种群分布仍按 `species_id` 写在代码分支中。[fish_local_authority.gd](../scripts/fish_local_authority.gd#L7) [学校生成逻辑](../scripts/fish_local_authority.gd#L165)

性能机制包括：鱼群使用 MultiMesh 批绘制；不为每条鱼创建场景节点或碰撞体；客户端个体运动以低频更新并插值；附近个体复用 4 米 DTM 缓存；水面高度按学校采样；表层涟漪最多 72 个实例、最多取 12 个学校；地图只在打开时刷新。全局渲染上限为 360 条，并按物种代码分配配额。[fish_school_renderer.gd](../scripts/fish_school_renderer.gd#L17) [鱼群渲染筛选](../scripts/fish_school_renderer.gd#L622) [fish_surface_activity.gd](../scripts/fish_surface_activity.gd#L7)

## 2. 现有字段覆盖与缺口

| 项目 | 现状 |
|---|---|
| 鱼种身份 | 有稳定字符串 `species_id`，但没有学名、分类确认状态或生命周期阶段。数值 `species_index` 参与确定性随机种子，不适合作为稳定身份。 |
| 海底水深 | 有最小/最大及偏好水深，用于适宜度和生成；这是游戏参数，不是调查数据。 |
| 游泳深度 | 有 `activity_depth_m`，与水深分开保存；针鱼/鲱鱼有表层与深层循环，三刺鱼由独立代码控制。 |
| 昼夜 | 没有昼夜行为。当前表层/深层转换按模拟秒和随机时长，不读取世界时间。 |
| 季节 | 没有鱼类季节字段，也没有鱼群与日历的连接。 |
| 栖息地 | 只有按水深生成的粗分类和三刺鱼海草权重；没有底质、盐度、水温、河口或海草调查数据。 |
| 群游 | 有学校聚合状态和 population；三刺鱼分组规模分布硬编码在权威代码中。 |
| 摄食 | 没有食性、猎物或觅食行为字段。 |
| 模型绑定 | 三个现有鱼种有模型路径与朝向参数。渲染器只读取模型的第一个 `MeshInstance3D` 和第一个 surface 的材质信息，不是通用多材质模型绑定。 |
| 钓鱼适配 | 没有钓鱼系统、FishingProfile、钓具配置或咬钩计算入口。 |
| 本地化 | 鱼类资源含中文、英文显示名称和硬编码栖息地描述；F4 UI 也直接写显示文本。鱼类路径中未发现专用翻译键使用。 |

现有 F4 的显示名直接读取 `display_name`、`english_name`、`habitat_description`。[fish_resource_map.gd](../scripts/fish_resource_map.gd#L323) 这不符合“显示文本只由稳定 localization key 引用”的要求。

## 3. 视觉鱼与逻辑鱼重复计数风险

当前实现**没有发现视觉鱼、逻辑鱼被重复计入权威种群的路径**：

- `FishSchoolState.population` 是本地权威学校的人数。
- 渲染器以学校快照为输入，生成有限数量的客户端视觉个体；单个学校最多绘制其 population、物种配额和全局预算允许的数量。[fish_school_renderer.gd](../scripts/fish_school_renderer.gd#L647)
- 针鱼和鲱鱼超过约 6 米活动深度时，仍保留同一权威学校，只是不绘制 3D 鱼体。[fish_resource_manager.gd](../scripts/fish_resource_manager.gd#L130)
- 涟漪和 F4 地图是同一学校的视觉表现，不会增加 population。
- `get_resource_density_at()` 从权威查询学校与 population，不查询 MultiMesh 或渲染数量。[fish_resource_manager.gd](../scripts/fish_resource_manager.gd#L137)

有两个需要防止误用的语义风险：

1. `get_resource_density_at()` 返回的 `density` 实际是 1200 米范围内的学校数，不是按面积归一的生物密度。
2. 可见个体数受渲染预算限制，可能远少于 population。未来中鱼率应查询权威种群与钓鱼状态，不能由屏幕可见条数、MultiMesh 数量或 F4 标记数量推导。

此外，“单个学校是一个真实群体”的粒度是原型建模选择，不等同于已调查的局部鱼群数量。

## 4. 水深、游泳深度与坐标衔接

项目使用本地 ENU 风格坐标：X 向东、Z 向南、Y 向上。DTM 查询会把输入位置的 Y 强制归零，因此返回的是相对于海图基准 LAT 的水深，与波浪瞬时高度无关。[bathymetry_manager.gd](../scripts/bathymetry_manager.gd#L114)

`FishSchoolState.depth_m` 表示海图水深；`activity_depth_m` 表示鱼在水柱中的活动深度。渲染器查询 `WaveSampler` 的局部水面高度，然后把鱼的世界 Y 放在“水面高度减去游泳深度”的位置。它也会按局部海底深度施加净空约束。[fish_school_state.gd](../scripts/fish_school_state.gd#L14) [鱼体垂向放置](../scripts/fish_school_renderer.gd#L1218) [wave_sampler.gd](../scripts/wave_sampler.gd#L380)

建议新 schema 使用明确名称，例如：

- `chart_depth_below_lat_m`
- `swim_depth_below_surface_m`
- `bottom_clearance_m`

这样能避免把海图水深、距瞬时水面的深度和距海底高度混为一个值。

## 5. 建议的最小数据 Schema

所有资源只保存**静态鱼种配置**。不把区域种群、个体状态、渲染预算或钓具参数复制进每个鱼种。

| Resource | 建议字段 |
|---|---|
| `FishSpecies` | `species_id`（稳定 ID）、`scientific_name`、`name_key`、`description_key`、`profile_version`、`habitat_profile`、`behavior_profile`、`visual_profile`、可选 `fishing_profile` |
| `HabitatProfile` | 海图水深可用/偏好范围、最低水柱、栖息地标签及适宜度权重、可选季节窗口；盐度/温度字段仅在环境系统提供可信输入后启用 |
| `BehaviorProfile` | 水层偏好、表层/深层活动范围、底部净空、学校规模分布、游泳速度、群游参数、昼夜活动曲线、食性/猎物标签 |
| `VisualProfile` | 可选模型资源绑定、朝向轴、头部方向、实际展示长度或模型缩放、动画参数、材质/颜色、导入状态 |
| `FishingProfile` | 可选是否可作为目标、饵料/拟饵标签、适宜鱼体长度范围、觅食时段/季节权重；没有钓鱼系统前默认禁用，不伪造命中率 |
| `FishPopulationState` | 由权威维护的区域/学校种群数量或生物量、位置、资源状态、更新时间及版本。若学校本身就是唯一种群单位，就沿用 `FishSchoolState`，不要再存一份可不一致的区域总量。 |
| `FishIndividualState` | 只在需要钓获或近距离个体交互时创建：个体 ID、鱼种 ID、长度/生命周期、位置、水层、学校 ID、状态。无需为全区域每条鱼建立对象。 |
| `FishRenderBudget` | 全局/平台级的半径、最大可见数量、每类视觉优先级、更新频率和 LOD。它不决定鱼群数量或咬钩概率。 |
| `FishingTackleProfile` | 独立于鱼种：钓竿、线组、钩型、拟饵、呈现深度、收线方式等参数。咬钩由钓具、鱼种、海域种群和活动状态组合计算。 |

现有学校状态已经含 `species_id`、数量、位置、水深、游泳深度和资源状态，并能序列化。[fish_school_state.gd](../scripts/fish_school_state.gd#L26) 但它是学校聚合状态，不是鱼个体存档。

## 6. 四鱼种配置草案

下表的现有数值来自项目 profile。生态来源只支持相对行为和栖息地标签；水深区间、出生概率、学校数量与速度大多属于游戏调校，不能解释为当地普查结果。

| 鱼种 | 建议默认值与处理 |
|---|---|
| 三刺鱼 `three_spined_stickleback` | 保留兼容基线：海图水深 **0.8–6 m**，偏好 **1.3–3.3 m**，海草边缘标签；当前游泳目标约 **0.45–1.5 m**。学校分布保留现有 **15%：5–10、75%：12–25、10%：26–40**，但迁入 BehaviorProfile。浅海植被与生命周期阶段有关，不能把当前浅水配置当作该鱼种全生命周期范围；HaV 资料同时指出该种分布于多种水体、可在开阔水域出现，而浅海繁殖是其生命周期的一部分。[HaV 三刺鱼资料](https://www.havochvatten.se/arter-och-livsmiljoer/arter-och-naturtyper/storspigg.html) [SLU 浅海湾阶段差异研究](https://research.slu.se/en/publications/juvenile-and-adult-three-spined-sticklebacks-exhibit-different-habitat-use-in-shallow-baltic-sea-bays/) |
| 针鱼，建议先核实物种身份 | 如果确认是当地的 *Belone belone*，保留现有海图水深 **2–42 m**、偏好 **4–19 m**、表层活动 **0.4–1.8 m**、深层活动 **3.8–9 m**、学校 **3–10**。建议游戏存在季节窗口先用 **5–9 月**作为可调近似；当地资料记载该鱼夏季常见、春季近岸繁殖、夏末迁出。水深区间和数值速度仍是游戏估计。[HaV 针鱼资料](https://www.havochvatten.se/arter-och-livsmiljoer/arter-och-naturtyper/horngadda.html) |
| 鲱鱼 `herring` | 兼容范围 **8–53 m**、偏好 **17–43 m**、学校 **35–96**。保留现有表层 **0.7–2.5 m**、深层 **8–24 m** 作为游戏参数。行为建议迁移到昼夜活动曲线：白天偏深，黄昏/夜间偏浅；确切深度应受实际水深限制。ICES 资料支持鲱鱼大群游及昼夜垂直迁移，也指出其深度随年龄、食物和水文条件变化；现有绝对深度和学校规模仍属本游戏近似。[ICES 鲱鱼资料](https://www.ices.dk/about-ICES/projects/EU-RFP/EU%20Repository/ICES%20FIshMap/ICES%20FishMap%20species%20factsheet-herring.pdf) |
| 海鳟 `sea_trout`（建议新稳定 ID，待确认） | 仅登记物种元数据，视觉绑定标为 pending，**不自动生成、不启用钓获**。生态标签可预留 `coastal_brackish`、`estuary`、`connected_freshwater`；暂不填当地水深偏好、种群量和活动深度。海鳟为迁徙型生活史，海域摄食并返回淡水繁殖，但当前鱼类系统没有河流网络或河口连通数据，因此不能可靠放置繁殖种群。[HELCOM 鱼群资料](https://helcom.fi/action-areas/fisheries/fish-communities/) [HaV 海鳟生态报告](https://www.havochvatten.se/data-kartor-och-rapporter/rapporter-och-andra-publikationer/aldre-publikationer/finfo/2012-02-01-finfo-200110-havsoringens-ekologi.html) |

**模型绑定说明：**工作区中可见 `assets/fishes/seetrout.glb` 文件，但当前鱼种配置及管理器均未引用它。先把海鳟视觉配置置为待绑定；接入前确认导入状态、模型朝向、表面数和材质。不能由文件名推定物种来源或模型朝向。

**尺寸风险：**当前配置的 `target_visual_length_m` 是渲染尺寸输入，不是可用于生态或钓获的鱼体长度；针鱼和鲱鱼的视觉缩放倍率还会扩大该数值，三刺鱼的展示尺寸也明显偏向可见性。未来钓获重量/长度数据必须来自独立的个体尺寸字段，不能复用当前视觉尺寸。[fish_school_renderer.gd](../scripts/fish_school_renderer.gd#L1424)

## 7. 存档、本地化和迁移建议

当前 `FishSchoolState` 写 schema 2，并读取 schema 1/2；权威快照是 schema 1、layout 3，恢复时要求布局版本完全相同。[fish_school_state.gd](../scripts/fish_school_state.gd#L26) [fish_local_authority.gd](../scripts/fish_local_authority.gd#L117) 现有快照可序列化，但项目文档说明还没有持久化的鱼类存档文件。[fish_resources/REPORT.md](./fish_resources/REPORT.md#L41)

建议分阶段迁移：

1. 固定三个现有 `species_id` 和当前 profile 数值作为兼容基线；新增配置不能重排 `species_index`，因为它参与随机生成。
2. 新增 `FishSpecies` 和嵌套 profile 后，先让旧 `.tres` 通过适配器继续供 Authority、Renderer 和 F4 使用。逐个迁移行为字段，暂不整体重写。
3. 扩展快照时向前兼容旧学校 schema。布局变化需显式迁移；当前 layout 不同会直接拒绝恢复。将来可把随机种子从索引改为稳定 ID 派生，但需确认是否允许世界种群位置变化。
4. 把所有玩家可见鱼种名称、说明、栖息地和状态标签改为稳定翻译键，例如 `fish.species.herring.name`，由界面调用翻译。存档只写 `species_id` 和数值，不写翻译后的文本或本地化键。
5. 海鳟先以禁用的待绑定 profile 注册，不参与生成、渲染和钓鱼，等物种身份、河口/河流数据和模型确认后再启用。

本地 Authority 的 population 变更当前只允许减少，不支持自然恢复；未来若加入持续世界和钓鱼消耗，需要另行定义补充、繁殖或重置规则。[fish_local_authority.gd](../scripts/fish_local_authority.gd#L103)

## 8. 自动化验收标准

后续实现可以用以下标准验收：

- 所有鱼种 ID 唯一稳定；重排 Profile 或新增鱼种不改变现有三种的确定性布局。
- 旧学校 schema 1/2 能读取；新增状态有默认值；不兼容布局有明确迁移测试。
- 关闭渲染、把渲染上限设为 0、切换 F4 筛选或改变视觉预算，Authority 的学校数和 population 均不变。
- 每个视觉实例都能追溯到 `school_id`；F4、涟漪和视觉鱼不增加权威计数。
- DTM 查询对输入 Y 不敏感；鱼的世界 Y 与波浪水面减游泳深度一致，且满足水底净空。
- 所有鱼类 UI 文本使用翻译键；保存数据只含稳定 ID 与数值。
- 海鳟待绑定时不导致资源加载错误、不生成鱼，也不被钓鱼系统识别为可捕获对象。
- 渲染上限、每种视觉权重及更新频率与种群配置相互独立。

本轮按只读要求没有运行这些测试，也没有更改项目文件。

## 9. 需要决策的事项

1. “针鱼”是否确定指 *Belone belone*？现有 ID 可以保留，但学名应确认后写入。
2. 当前 Øresund 区域的鱼量是固定游戏资源，还是未来需要季节迁徙、自然恢复和长期耗竭？
3. 海鳟是否要等河流/河口连通数据到位后再生成？建议在那之前保持禁用。
4. 钓鱼玩法希望偏休闲捕获还是需要尺寸、季节和放流规则？这决定 FishingProfile 的字段和数值。
5. 昼夜/季节是否应改变鱼的活动与出现，还是只作为视觉背景？
6. 最终需要哪些界面语言？这决定翻译目录和稳定 key 的维护方式。

## 结论

现有项目已具备可扩展的学校级权威、视觉渲染与预测地图基础；主要缺口是混合型鱼种 Resource、若干按 ID 硬编码的行为、季节/食性/钓鱼数据和本地化键。推荐通过兼容适配、逐项迁出数据和明确的版本迁移来演进，保持渲染预算与生态数量完全分离。
