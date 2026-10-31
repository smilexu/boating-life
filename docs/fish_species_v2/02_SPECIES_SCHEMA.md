# P1.1 FishSpeciesProfile Schema

**状态：**PASS  
**阶段目标：**保留现有 `FishSpeciesProfile` Resource，以 Godot export groups 清晰分组；新增稳定分类/本地化元数据、真实鱼体长度和可供现有通用行为消费的配置，避免为架构而拆成嵌套 Resource。  
**预计修改：**`scripts/fish_species_profile.gd`、三份 `resources/fish_species/*.tres`、F4 与船舶 HUD 名称读取；本阶段不改生成算法。  
**验收：**稳定 ID 和配置能加载；分组字段无重复；旧鱼测试入口可运行。

## 现状与结构决策

> 兼容政策按 2026-10-30 用户修正：不要求旧布局坐标、学校分布、随机调用顺序或 `species_index` 顺序一致。稳定 `species_id` 保留；旧快照需在 schema/layout 版本变化后明确拒绝/重新生成并记录。

当前 `FishSpeciesProfile` 是一个扁平 Resource，已经被 Authority、Renderer、F4 和测试直接消费。为了降低迁移风险，本阶段继续使用该类和现有 `.tres` 资源，不新增 `HabitatProfile` 等子 Resource。

通过 `@export_group` 组织数据：

| 分组 | 字段 | 所属/用途 | 消费者/说明 |
|---|---|---|---|
| Identity | `species_id`, `species_index`, `scientific_name`, `name_key`, `description_key`, `body_length_range_m` | 鱼种静态身份及现实鱼体长度范围 | ID 是稳定存档身份；index 仅用于当前配置排序，可重新分配，不作身份或生态随机 salt；稳定 key 由 F4 翻译；体长范围不等于视觉模型尺寸 |
| Ecology | `minimum_depth_m`, `maximum_depth_m`, `preferred_depth_min_m`, `preferred_depth_max_m`, `spawn_chance`, `eelgrass_spawn_boost`, `vegetation_spawn_mode` | 海图 LAT 水深适宜度与确定性生成 | Authority；不混入游泳深度、盐度、河口、底质或温度 |
| Behavior | `behavior_type`, `population_min/max`, optional weighted school-size bands, speed range, vertical layer, surface/deep cycle ranges/shares, depth/flee/near-surface tuning, activity radius, water column, cycle flag derivation | 学校及已有的个体行为静态调校 | Authority/Renderer。学校规模由配置区间或加权档位和带种子 RNG 选择；开发版不承诺旧随机调用形状 |
| Visual | model path/axis/head direction, `visual_enabled`, logical depth threshold, per-species rendering share, target visual length/range/scale/roughness, map color, body wave/tail frequency | 表示与动画，不控制生态数量 | Renderer/manager/F4。全局 maximum visible fish 仍是 Renderer 的预算；视觉鱼数不会回写人口 |
| Fishing | `supported_fishing_methods`, `compatible_lure_tags`, `relative_bite_tendency` | 只为未来选目标/过滤器准备 | 本阶段没有消费者，不实现咬钩概率。真实体长范围复用 Identity 字段，不在 Fishing 复制 |

## 重复/无消费者处理

- `body_length_range_m` 与 `target_visual_length_m` 不同义：前者是鱼种真实体长区间，后者是当前 MultiMesh 绘制长度。模型倍率只用于视觉。
- `depth_m` 是每个学校的海图水深；`activity_depth_m` 是距当时局部海面的游泳深度；Profile 里的 swim-depth 范围属于后者。DTM 和 WaveSampler 链路保持独立。
- `species_index` 不是身份 ID；它可以随新版重新分配。当前仅用于 Profile 遍历顺序；鱼种随机 salt 由稳定 `species_id` 派生。确定性来自同一份世界种子、Profile 配置与初始状态。旧快照与当前 ID/Schema/layout 或生态配置不匹配时会明确拒绝。
- `population_min/max` 表示简单学校大小；可选 `school_size_ranges` + `school_size_band_weights` 提供离散分布。开发版允许调整这些数据。
- `visual_budget_share` 是全局可见预算的分配权重；不含渲染数上限，也不改变 `FishSchoolState.population`。
- 钓法/tag/相对倾向是用户明确要求的未来接口，当前未接入捕获或中鱼率；其数值只是筛选/相对调校初值，不表示真实钓获率。
- `description_key` 可以为空，F4 用名称 key 加可计算数值字段。不会把描述翻译字符串写入 Profile 或存档。

## 旧字段迁移映射

| 旧字段 | 新用途 | 迁移策略 |
|---|---|---|
| `display_name` | `name_key` | 从 `.tres` 移除直接显示字符串；保留稳定 ID 对应 key，例如 `fish.species.herring.name` |
| `english_name` | `name_key` | 不再保存第二份显示名称，按当前 TranslationServer locale 查 key |
| `habitat_description` | `description_key` + Profile 数值字段 | 删除自由文本；F4 以翻译 key 和水深/活动范围拼装，避免将数字重复写在翻译中 |
| `minimum_depth_m` / `maximum_depth_m` | 原样保留 | 明确语义为海图水深 LAT |
| `surface_activity_depth_m` / `deep_activity_depth_m` | 原样保留 | 表示局部水面以下游泳深度 |
| `population_min/max` | 简单学校规模分布 | 开发版允许调整；新分布只需可复现并满足生态范围 |
| `target_visual_length_m`, `visual_length_range_m`, `visual_scale_multiplier` | 原样保留 | 只用于渲染 |
| renderer/authority 中按物种硬编码的生成差异 | Profile enum/数组或统一算法 | 开发版允许调整、简化和重校；旧布局不是门槛，验收关注约束符合配置和新版确定性 |

## 初始旧物种长度/本地化数据

学名确认：针鱼是 *Belone belone*（HaV 页面使用 Horngädda/Näbbgädda）；三刺鱼为 *Gasterosteus aculeatus* 复合种在现有本地配置中采用的种级身份；鲱鱼为 *Clupea harengus*。若未找到能支持本地物种亚种的证据，则不把旧三刺鱼文件名扩展成更细分类。

鱼体长范围参考权威资料边界并采用明确的游戏化范围；海鳟字段限定海水生活阶段，不表示河流/繁殖行为。

生态资料参考：

- [HaV：Horngädda / *Belone belone*](https://www.havochvatten.se/arter-och-livsmiljoer/arter-och-naturtyper/horngadda.html) — 夏季分布、表层、群游、食物及最长约 1 m。
- [HaV：Öring / *Salmo trutta*](https://www.havochvatten.se/arter-och-livsmiljoer/arter-och-naturtyper/oring.html) — 同种可海洄游；海鳟以海水生长并返回淡水繁殖，本原型不模拟该繁殖阶段。
- 三刺鱼的当前浅水/海草代理和鲱鱼的学校规模、活动深度以 P1.0 可复现基线为准，不将游戏数值包装成普查参数。鲱鱼昼夜循环首阶段保持旧的游戏时长规则，不新增季节/昼夜调制。

## 阶段完成记录

- 已在 `FishSpeciesProfile` 用同一 Resource 完成分组；未拆嵌套 Resource。
- 三份 `.tres` 以稳定 `species_id` 保存 key 与学名，移除 `display_name` / `english_name` / `habitat_description` 可见字符串。
- `fish_resource_map.gd` 和 `boat_hud.gd` 名称读取切换为 `tr(name_key)`。当前项目无已注册 Translation catalog，P1.4 尚待添加具体词条。
- 长度区间：三刺鱼 0.02–0.11m（HaV海水上限11cm；下界游戏化）；针鱼0.25–1.00m（HaV最大约1m；下界游戏化）；鲱鱼0.15–0.45m（共通长度/最大范围参考FishBase；下界游戏化）。
- 首次测试曾发现 HUD 仍读取已删除属性，已修复后复跑：两条测试均退出码0、`failures=0`。Headless 退出仍有 DummyShader RID leak 警告。
- 用户修正确认开发阶段可以重建旧布局；P1.0 数量/位置仅为差异基线，不是兼容门槛。Forward+ 模型画面检查仍为 `NOT RUN`。

**P1.1 状态：PASS。**

### 2026-10-30 完成核验

- 单一 `FishSpeciesProfile` Resource 已按 Identity/Ecology/Behavior/Visual/Fishing 分组；没有拆嵌套配置 Resource，也未加入本阶段没有可靠数据来源的盐度、水温、底质或繁殖字段。
- 四份 Profile 均能加载；可见名称与说明使用稳定 key，模型显示长度与真实体长范围分离；海鳟 fishing fields 仅为未来配置，不存在钓鱼消费者。
- `FishSchoolState.population` 是权威数量；Renderer 继续使用每鱼种 MultiMesh。自动测试改变 `maximum_visible_fish` 后总权威数量不变。
- 测试与本地化结果见 `07_TEST_RESULTS.md`。
