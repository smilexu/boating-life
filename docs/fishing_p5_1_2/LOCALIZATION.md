# HUD 本地化

- 支持 locale：`zh_CN` 与 `en`。
- 复用现有 `/root/LocalizationManager`、TranslationServer 和 `resources/translations/fish_species.csv`，没有建立另一套翻译管理器。
- 设置页语言控件调用现有 LocalizationManager；选择会持久化，locale 信号触发打开中的游戏菜单、环境/活动/航行面板、帆船仪表、海图、鱼探仪与拖钓面板立即刷新。
- 航行状态、拖钓状态、鱼探仪模式和水层匹配使用稳定 ID/枚举决定逻辑；翻译只用于呈现。
- 新增/更新的键覆盖环境摘要、活动、操作帮助、航行信息、帆船状态、拖钓状态/提示/水层匹配、鱼探仪和海图标签，以及设置和预览卡片中本轮触及的文字。
- 翻译导入使用 `godot --headless --path . --editor --quit`。导入成功；编辑器仍提示两个既有 `docs/` 翻译产物 UID 重复，与本次 HUD 翻译无关。
