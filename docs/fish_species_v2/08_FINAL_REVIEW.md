# Fish Species V2 / P1 最终审查

**状态：PASS（自动与 Headless 验证）；Forward+ 目视验收：NOT RUN**  
**日期：**2026-10-30  
**引擎：**Godot 4.7.2 stable official

## 1. 本次结果

- 将现有 `FishSpeciesProfile` 改为 Identity / Ecology / Behavior / Visual / Fishing 分组的单一扁平 Resource，并把四鱼种学校生成、生态边界、行为调校和视觉参数统一从 Profile 读取。
- 新增 Sea Trout (`sea_trout`, *Salmo trutta*)，复用已有 Local Authority、学校状态、表/深水层管理、F4 与 MultiMesh renderer。
- 保留针鱼、鲱鱼、三刺鱼的稳定 `species_id`。不保留开发期旧坐标、学校分布、随机调用顺序或旧 `species_index` 排列；新版在同样 seed、Profile 配置和初始状态下确定性生成。
- 鱼类名称、说明、F4 鱼类资源页及 F3 鱼群观察 HUD 使用稳定 localization key；新增 `en` 和 `zh_CN` 词条。Fish profile/snapshot 保存 key、稳定 ID 和数值，不存翻译文本。
- 新增依赖 WorldTimeManager 游戏时间的学校数量恢复基础，不连接任何钓鱼或捕捞玩法。

## 2. 关键代码与结构

- `scripts/fish_species_profile.gd:7`：分组字段；真实体长和视觉显示长度分开；`species_index` 仅用于排序，不作稳定身份或生态 hash salt。
- `scripts/fish_local_authority.gd:7`：当前 layout v5、authority snapshot schema 3；`:194` 生成不依赖 index 顺序的生态 Profile signature；`:261` 按 Profile 生成学校；`:367` 执行时间驱动恢复。
- `scripts/fish_school_state.gd:27`：学校恢复基线、游戏时间戳、小数恢复余量；旧 school schema 2 明确拒绝。
- `scripts/fish_resource_manager.gd:230`：注册四种默认 Profile；`:246` 从 `WorldTimeManager` 读取绝对游戏时间。
- `scripts/fish_school_renderer.gd:604`：每鱼种保留 `MultiMeshInstance3D`；Authority population 不受可见鱼预算影响。
- `scripts/boat_hud.gd:1709`、`:1897`：F3 鱼种观察控件和状态使用 key。
- `scripts/fish_resource_map.gd:202`、`:562`：F4 鱼类资源页和学校详情使用 key/翻译格式。
- `resources/translations/fish_species.csv`：英文及简体中文词条；`project.godot` 注册导入的 Translation 资源。

## 3. Profile 与四鱼种初始值

这些是游戏生态调校值，不表示本地渔业普查结果。海图水深指 LAT 下海床深度；活动水层指距当前局部海面的游泳深度，两者独立。

| Stable ID | 学名 | 海图适生 / 偏好深度 | 活动水层 | 每校数量 | 备注 |
|---|---|---|---|---:|---|
| `needlefish` | *Belone belone* | 2–42 m / 4–19 m | 表层周期 0.4–1.8 m、深层 3.8–9 m | 3–10 | 相对生成概率 0.24；快速远洋行为 |
| `herring` | *Clupea harengus* | 8–53 m / 17–43 m | 表层周期 0.7–2.5 m、深层 8–24 m | 35–96 | 相对生成概率 0.27；群游行为 |
| `three_spined_stickleback` | *Gasterosteus aculeatus* | 0.8–6 m / 1.3–3.3 m | 由浅水底栖行为参数控制 | 5–40 | 相对生成概率 0.38；保留配置化的海草边缘偏好及加权学校规模 |
| `sea_trout` | *Salmo trutta* | 2–25 m / 3–12 m | 表层 0.5–5 m、深层 6.5–12 m | 1–3 | 相对生成概率 0.015；38 校/84 尾；Fishing 配置仅登记拖钓与拟饵标签 |

修改前 P1.0 基线与新版固定 seed 统计如下。新版差异是明确允许的重新调校和 stable-ID hash 变化，并非旧位置/数量兼容回归失败：

| 物种 | P1.0 修改前：学校 / population | 新版 seed 20261016：学校 / population |
|---|---:|---:|
| needlefish | 857 / 5,499 | 863 / 5,657 |
| herring | 392 / 25,528 | 461 / 30,025 |
| three_spined_stickleback | 166 / 3,175 | 148 / 3,201 |
| sea_trout | 未接入 | 38 / 84 |
| 合计 | 1,415 / 34,202 | 1,510 / 38,967 |

Snapshot policy：学校 schema 2、authority schema 2/layout 4 及其他不匹配布局明确拒绝；当前学校 schema 3、authority snapshot schema 3/layout 5。Profile signature 不包含 index 排序且以 stable ID 排序；测试确认仅重排 index 不改变学校布局，也不使语义相同的快照失效。生态配置变化会拒绝旧 snapshot。当前没有单独鱼类持久存档文件，因此无需迁移或静默解释旧玩家文件。

## 4. 海鳟模型与渲染

- 新 Profile：`resources/fish_species/sea_trout.tres`；模型继续使用用户已有 `assets/fishes/seetrout.glb`，未改 GLB 源模型。
- Godot 导入检查得到一个 `MeshInstance3D`、一个 Mesh surface 与 Base Color 纹理，AABB 约 `(1.1681, 0.1386, 0.3335) m`；匹配现有 renderer 的单 Mesh/Surface 适配路径。导入生成 `.import` 文件和纹理资源。
- Sea Trout 在当前 DTM 下以 Profile 水深条件生成；既有测试确认学校位置是有效水域且满足配置水深/人口边界，F4 可查询，深层状态仍保留 Authority 学校。
- 结构/纹理资源可加载：PASS。Forward+ 实际画面中的模型朝向、法线、材质外观、鱼体比例及水下可见性：**NOT RUN**，需在图形界面人工确认。

## 5. 本地化

- 新增 `resources/translations/fish_species.csv`、`.import`、`fish_species.en.translation`、`fish_species.zh_CN.translation`，并在 `project.godot` 注册。
- 鱼种名称、说明、F4 鱼类筛选/图例/详情、F3 观察与状态提示均通过稳定 key；两种现有项目可用语言均被自动测试解析。
- `scientific_name` 作为拉丁学名元数据直显；存档不写入翻译后的名称。钓法、拟饵标签、relative bite tendency 尚无消费者，不产生玩家中鱼行为。

## 6. Population 恢复

- 在 `FishSchoolState` 保留原学校 baseline、最近更新时间和 `[0,1)` 小数余量，不另建一份重复的全局 population 表。
- Local Authority 对已经耗减的学校按 `N(t)=K-(K-N0)e^(-0.006t)` 恢复，`t` 为游戏小时；恢复在现有每 8 秒批处理里发生，不按渲染帧遍历全部学校。零数量学校保留 stable ID；人口到 1 后回到 active snapshot；恢复永不超过 baseline。
- 世界时间倒退时重置时间锚点，暂停时不恢复。当前没有捕捞系统；恢复用测试扣减入口模拟，后续接入捕捞时应使用现有 Authority 人口变更接口并提供游戏时间。

## 7. 测试结果

| 检查 | 结果 |
|---|---|
| `godot --headless --editor --path . --quit` | PASS，exit 0；鱼类资源导入成功 |
| `tests/test_fish_resources.gd` | PASS，exit 0，`failures=0`；四鱼生态、确定性、快照、双语 F3/F4、模型结构及 MultiMesh 预算隔离 |
| `tests/test_surface_fish_visibility.gd` | PASS，exit 0，`failures=0`；表/深层 Authority、F3/F4 以及观察不改变生态状态 |
| `tests/test_fish_population_recovery.gd` | PASS，exit 0，14 项 PASS，`failures=0` |
| `git diff --check` | PASS；最终运行结果见任务结束时的复核 |
| Forward+ Sea Trout / F4 视觉验收 | NOT RUN；Headless 显示 `No rendering device on load` |

Headless 测试退出有 DummyShader RID leak warning；编辑器扫描有一个 ObjectDB 退出 warning。扫描还报告两对已有 sailing `.translation` UID 重复警告，路径位于 P2.5/P2.15 文档数据，与鱼类翻译导入无关。测试 exit 0 且脚本 failure counter 为 0；这些退出 warning 没有被解释为已经证明无泄漏。

Authority 集成测试本次记录：固定 seed 生成 1,510 个学校；多次 Headless 运行初始化约 318–329 ms、16 个 budgeted step frame 的累计计算约 733–780 ms，最坏单帧约 2.12–5.07 ms。计时有测试环境波动，不是发行版本帧率或视觉性能结论。

## 8. 修改文件

- 项目翻译注册：`project.godot`。
- Profile/schema：`scripts/fish_species_profile.gd`、`resources/fish_species/{needlefish,herring,three_spined_stickleback}.tres`、新增 `resources/fish_species/sea_trout.tres`。
- Authority 与恢复：`scripts/fish_authority_adapter.gd`、`fish_local_authority.gd`、`fish_resource_manager.gd`、`fish_school_state.gd`。
- 视觉与 UI：`scripts/fish_school_renderer.gd`、`fish_surface_activity.gd`、`fish_resource_map.gd`、`boat_hud.gd`。
- 新翻译源/导入结果：`resources/translations/fish_species.csv` 及其 `.import`、英文和简体中文 `.translation`。
- Sea Trout 导入生成资源：`assets/fishes/seetrout.glb.import` 和对应导出的纹理/`.import` 文件；原始 GLB 保持未修改。
- 测试：更新 `tests/test_fish_resources.gd`、`tests/test_surface_fish_visibility.gd`；新增 `tests/test_fish_population_recovery.gd` 与 Godot UID sidecar。
- 阶段文档：`docs/fish_species_v2/00_IMPLEMENTATION_PLAN.md` 至 `08_FINAL_REVIEW.md`。
- 既有审核文档 `docs/fish_species_ecology_audit.md` 保持原样，没有纳入本次实现修改。

## 9. 限制与下一步接口

- Sea Trout 来源 GLB 已用 Blender 侧视图确认嘴/吻部在局部 −X、尾鳍在 +X，并已把 Profile 改为 Negative X。Godot Forward+ 主游戏实时画面仍需重启后检查游动方向、材质、尺寸及近水面/深水显示；Headless 不算此项验收。
- Profile 的 `supported_fishing_methods`、`compatible_lure_tags`、`relative_bite_tendency` 只是钓鱼系统预留字段；无消费者，不代表现有中鱼概率。
- 之后实现钓鱼时，应由权威学校 population 做扣减/恢复，使用稳定 `species_id`、钓具标签与真实体长范围；Graphics 档位和可见 MultiMesh 数量不能参与中鱼率或生态数量。
- 没有修改船舶、天气、水深、波浪或游戏时间系统，也没有运行长时间物理/Polar 扫描。

## 10. 2026-10-30 朝向复核补充

- `resources/fish_species/sea_trout.tres`：`model_forward_axis = 1`、`model_head_x = -0.4`。原因是来源模型中嘴/吻部在 −X、尾鳍在 +X；旧 +X 设置会让鱼尾朝向游动方向。
- Blender 5.2.1 侧视图和 `test_fish_resources.gd` 均已检查。Godot Forward+ 实际游戏画面尚未检查；运行中的旧游戏需重新加载场景/重启后才会读取新 Profile。

## 11. 2026-10-30 鱼类日常速度规则补充

- 日常巡游和转向现在采用相同速度上限；`fast_pelagic`、`coastal_benthic` 和 `free_swim` 的随机日常 burst 已移除。转向仍改变方向，但不再降低速度上限，也不会获得额外推进。
- 受惊逃逸使用现有扰动状态，逃逸速度上限为 `base_speed * 2.5`。鱼种巡游基准速度与种群数量未调整；规则适用于鱼类共用 renderer，独立海豚行为未修改。
- 修改文件：`scripts/fish_school_renderer.gd`、`scripts/fish_species_profile.gd`、`scripts/fish_local_authority.gd`、`resources/fish_species/needlefish.tres`、`resources/fish_species/sea_trout.tres`，以及本目录实施/测试记录。
- 鱼类自动测试与 Forward+ 实机观察均 **NOT RUN**。更改需重新加载/重启当前游戏实例后观察，未声称已验证主观游速。
