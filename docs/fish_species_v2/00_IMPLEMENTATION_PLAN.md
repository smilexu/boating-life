# Fish Species V2 / P1 实施计划

**开始日期：**2026-10-30  
**总体状态：**PASS

## 后续行为调校（2026-10-30）

**状态：**PASS
**目标：**统一鱼类日常转向和巡游速度；只有惊吓逃逸状态使用 2.5 倍冲刺速度。海豚使用独立行为，不在本次范围内。
**预计修改：**`scripts/fish_school_renderer.gd`、`scripts/fish_species_profile.gd`、鱼类 Profile 资源和本目录相关阶段记录。
**实际结果：**鱼类共用选择器不再随机产生日常冲刺；巡游、转向、警戒和恢复状态共用基础速度上限；只有惊吓逃逸状态使用 2.5 倍 Profile 上限。海豚系统未修改。自动测试 `NOT RUN`（本轮未要求执行）。

## 阶段状态

| 阶段 | 状态 | 目标 |
|---|---|---|
| P1.0 现状与兼容基线 | PASS | 记录三种鱼基线、存档/调试入口、海鳟 GLB 导入与测试结果。 |
| P1.1 FishSpeciesProfile 整理 | PASS | 在现有 Resource 上按 Identity/Ecology/Behavior/Visual/Fishing 分组，加入 key、真实体长、学校规模分布、视觉预算及 Fishing 预留字段。 |
| P1.2 四鱼种数据迁移 | PASS | 将四鱼学校生成与活动配置统一由 Profile 驱动；稳定 ID 派生随机 salt；开发布局 v4。 |
| P1.3 海鳟接入 | PASS | 注册 `sea_trout` 并接入模型、学校、MultiMesh 与 F4 资源数据。 |
| P1.4 F4 本地化 | PASS | 使用项目已有语言/key 体系；鱼种、F4 鱼类页和 F3 鱼类观察文字使用稳定 key；不把本地化显示文本写入存档。 |
| P1.5 最小种群恢复 | PASS | 基于游戏时间、现有学校状态实现可控恢复；不接入捕鱼。 |
| P1.6 回归与最终审查 | PASS | 确定性、鱼种/模型、本地化、地图/可见层、恢复和资源导入自动检查通过；Forward+ 目视检查标记 NOT RUN。 |

## 全局不变量（按 2026-10-30 用户修正）

- 原有三鱼和海鳟保留稳定 `species_id`；`species_index` 可重新分配，不替代稳定身份。
- 开发版允许重新校准四鱼种生成权重、学校规模与栖息生态；相同种子、配置和初态仍须确定性生成。
- 不兼容的旧快照必须通过 schema/layout 版本明确拒绝并重新生成，不能静默重解释。
- 视觉渲染预算不改变权威种群。
- 海鳟只模拟海水阶段，不引入河流/繁殖系统。
- 不创建钓具、钓鱼动画、捕获系统或新模型。
- 每个阶段先记录目标/预计改动/验收，再记录实际决策与验证。
- 未执行的测试标为 NOT RUN。

## 阶段文件

- [基线审计](01_BASELINE_AUDIT.md)
- [Schema](02_SPECIES_SCHEMA.md)
- [三鱼种迁移](03_DATA_MIGRATION.md)
- [海鳟接入](04_SEA_TROUT_INTEGRATION.md)
- [本地化](05_LOCALIZATION.md)
- [种群恢复](06_POPULATION_RECOVERY.md)
- [测试结果](07_TEST_RESULTS.md)
- [最终审查](08_FINAL_REVIEW.md)
