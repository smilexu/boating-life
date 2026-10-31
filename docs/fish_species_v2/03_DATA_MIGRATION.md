# P1.2 旧三鱼 Profile 驱动迁移

**状态：**PASS  
**阶段目标：**让现有三种鱼的学校生成与通用行为参数由统一 Profile 配置驱动，消除可配置生成规则中的 `species_id` 分支。开发期允许重新分配 `species_index`、调整权重和学校规模。  
**预计修改：**`fish_species_profile.gd`、三份旧 `.tres`、`fish_local_authority.gd`、必要的 `fish_school_renderer.gd` / `fish_resource_manager.gd` / F4/F3 读取、fish tests。  
**验收：**新 layout 版本明确拒绝旧 schema/layout 快照；同 seed + 同 Profile 配置确定性；生成只在配置深度内；School size 匹配配置；渲染预算不改权威人口；三鱼通用行为有明确 Profile 驱动字段。

## 开始前的用户兼容策略修正

2026-10-30 用户明确：项目还处于开发阶段，不需保存旧三鱼坐标、学校分布、随机调用顺序或 `species_index` 顺序。稳定 `species_id` 必须保留；layout/schema 不兼容时可以清除/重建，但必须提高版本并记录。实现优先简洁、配置可扩展和确定性。

## 迁移决策

- `species_id` 保留 `needlefish`、`herring`、`three_spined_stickleback`。
- `species_index` 仅用于本版 Profile 遍历顺序，不是持久身份或生态随机 salt；可按配置重新分配。学校布局保持一致，snapshot ecology signature 按稳定 ID 排序并忽略 index，所以仅重排 index 不会让语义相同的 snapshot 失效。
- 学校遍历按 `(species_index, species_id)` 排序；随机 salt 与表层/深层周期参数基于 world seed + 稳定 species ID + map cell，不用 `species_index` 作身份或随机盐，因此重分配 index 或调整 Profile 输入顺序不改变每校身份/生成数值。
- `spawn_chance`、海图水深适宜度和可选海草权重是 Ecology 数据。海草以 `vegetation_spawn_mode` 区分 additive / edge preference。
- 学校 population 从配置的 min/max 或 weighted school-size bands 抽取；不再把鱼种规模分布硬编码在 Authority。
- 学校 movement label、表层/深层状态循环从 `behavior_type` / `surface_activity_cycle_enabled` 读取。个体运动算法 family 仅代表不同运动模型，不用稳定 ID 判断；可调生态值仍在 Profile。
- 渲染 share 与全局最大可见鱼数留在视觉系统，永不用于 `FishSchoolState.population` 或生成权重。
- P1.2 首先把 layout v3 改为 v4；P1.5 增加恢复状态后再升至当前 layout v5 / authority snapshot schema 3 / school schema 3。旧 v2/layout4 与更早 schema/layout 快照会明确拒绝，由当前开发版重新生成。游戏没有单独的持久鱼类存档文件；拒绝规则应用于 authority snapshot/测试快照。

## 原值保留与允许重调

当前 Profile 初始数值以 `01_BASELINE_AUDIT.md` 为旧版本参照。P1.2 会先将旧值移至字段，再通过四鱼联调判断是否需要重新设定，避免将旧分布误称为真实生态调查。实测新值和被调整的原因记在阶段完成记录与 `07_TEST_RESULTS.md`。

## 阶段完成记录

### 2026-10-30 完成记录

- 移除 `fish_local_authority.gd` 中依赖鱼种 ID 的学校权重/学校规模分支；四种鱼的水深适宜度、生成权重、学校人口范围/size bands、速度和活动层参数均来自 `FishSpeciesProfile`。通用生成/移动算法保留。
- 开发布局由 v3→v4；P1.5 加入恢复序列化后最终为 layout v5 / snapshot schema 3 / school state schema 3。`species_index` 不参与稳定 hash；静态回归将 index 全部反向重分配并反转 Profile 数组，布局签名仍一致。
- 确定性实测：固定 world seed `20261016` 和同一 Profile 配置生成相同学校 ID、位置和数量；更改 Sea Trout `spawn_chance` 会更改 Profile signature 并拒绝旧 snapshot。
- 当前四鱼学校数量为 needlefish 863、herring 461、stickleback 148、sea trout 38，共 1510（完整 Øresund DTM）。学校分布由 Profile 的适深概率和生成权重决定；渲染预算仅裁剪 MultiMesh 可见实例，自动测试确认它不改变权威总鱼数。
- `test_fish_resources.gd` 同时验证所有生成学校的真实水域、Profile 深度适配与 Profile 人口边界。具体每鱼种总人口在最终复测日志中记录。
- 没有增加视觉鱼和逻辑鱼各自的种群副本；F3/F4 消费同一 Authority 学校状态。三刺鱼浅水/海草 edge preference 保留为 Profile 参数和通用策略，不再使用身份 ID 分支。

**P1.2 状态：PASS。**

### 2026-10-30 修正与复核

- 复核发现本地 `sea_trout.tres` 实际仍为 `spawn_chance = 0.05`；此前工作摘要所说已降至 0.015 与工作区不符，因此在本次测试前更正为 0.015，并以测试计数核对。
- 发现 `_species_profile_signature()` 的格式占位符数量和参数数不一致，Godot 会打印格式错误；已改为稳定字段序列，避免格式串参数计数风险。
- 新布局随机 salt 已由稳定 `species_id` 派生；`species_index` 仅用于排序，不作鱼种身份或每鱼种生态随机 salt。索引变更不单独改变学校布局。
- 上述修正已在 `fish_local_authority.gd`、海鳟 Profile 与鱼类测试中完成；四鱼数量、水深约束、同配置确定性、Profiles 输入顺序不敏感和旧 layout 明确拒绝均通过。
