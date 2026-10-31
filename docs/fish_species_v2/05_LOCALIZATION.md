# P1.4 鱼种与 F4 本地化

**状态：**PASS  
**阶段目标：**使用稳定 translation key 显示四鱼种名称、生态简介、活动状态、F4 鱼类资源页和 F3 鱼群观察入口；Profile 和学校快照只存 key/ID/数值，不保存翻译文本。
**预计修改：**`resources/translations/fish_species.csv`、Godot 翻译导入/项目注册、`fish_resource_map.gd`、`boat_hud.gd`、鱼类本地化测试。  
**验收：**在现有资源支持范围内切换 English 与简体中文后，四个名称、简介、活动水层说明、图例及 F3 鱼类按钮由 key 解析；没有缺失 key 被显示为原始 key；stable species ID 不随语言改变。

## 语言决策

项目在本任务开始时未注册翻译目录或项目级 locale catalog。当前鱼类显示已有中文与英文命名线索，因此此阶段先提供 `en` 和 `zh_CN` 两列的鱼类词条；这不是最终发行语言范围声明。

## 阶段完成记录

### 2026-10-30 完成记录

- 新增 `resources/translations/fish_species.csv` 英文与简体中文列，并导入为 `.en.translation` / `.zh_CN.translation`；在 `project.godot` 中注册这两个翻译资源。没有新增其他语言声明。
- 四种鱼的 `name_key`、`description_key` 在 Profile 中保存稳定 ID 对应 key；快照只保存 `species_id`、学校数值和状态，不存翻译后的文字。
- F4 鱼种筛选图例和学校详情从翻译 key 生成，详情的栖息地、活动层、资源状态、显示层、位置/水深说明也使用 key；缺失 habitat/activity key 回退到 `unknown`。F3 鱼群观察状态、活动类型计数、可见/逻辑状态和动态鱼种按钮使用同一翻译 catalog。
- `test_fish_resources.gd` 运行时切换 `en` 与 `zh_CN`，逐一调用 F4 学校详情格式并验证四种鱼名已翻译、没有 `fish.map.*` 或 `%s` 原始占位符遗留；全部通过。
- 同一测试还验证 F4 鱼类页及 F3 鱼群观察 HUD 使用的全部静态/反馈文本 key 在 `en` 与 `zh_CN` 均能解析；相应脚本没有保留鱼类观察 UI 的硬编码中文文案。
- F4 中航路编辑/水深质量的既有普通界面文字仍保持项目原有中文 UI；本地化范围是鱼种名称、说明、鱼类栖息地/活动/状态及鱼类调试显示，不扩展到无关港口或航路系统。

**P1.4 状态：PASS。**
