# Fishing P5.1 + P5.2 实施摘要

## 已完成

- 将正常 HUD 整理为环境摘要、顶部罗盘、右上活动入口、左下海图和右下航行核心区。机动船与 Nordic 28 共用布局规则，帆船的详细操帆/自动舵信息按需展开。
- 右上活动菜单提供拖钓配置、鱼探仪和操作帮助。打开拖钓配置不会启动拖钓；进行中面板跟随 P2/P3 的真实状态，折叠不停止活动，停止后面板收起。
- 海图保留 mini / expanded / hidden 三种状态。展开海图与鱼探仪共用一个主要工具位；从活动菜单打开鱼探仪时暂时隐藏缩略海图，关闭后恢复。
- 增加基于真实 FishFinderSensor 历史的近期回波摘要，并将水下深度转换到水面基准后与钓饵工作水层比较。数据过期、过弱或无效时显示“近期未见鱼群”。此匹配只作提示，不改动咬钩概率。
- 显示拖钓船速状态时，复用 FishingEncounterSystem 的船速、巡航上限、最低有效速度、鱼种支持关系和速度效率曲线。
- 在现有设置页加入简体中文/英文语言选择；语言运行时立即刷新打开的 HUD，并由现有 LocalizationManager 保存。
- 新增针对 P5.1/P5.2 的纯逻辑测试；扩展 C8 主场景集成覆盖活动面板、语言切换、鱼探仪/海图以及帆船紧凑/展开仪表。

## 主要修改文件

- HUD 与工具：`scripts/boat_hud.gd`、`scripts/compass_hud.gd`、`scripts/fish_resource_map.gd`、`scripts/fish_finder_display.gd`、`scripts/fishing_player_panel.gd`。
- 设置与语言刷新：`scripts/game_menu.gd`、`scripts/graphics_settings_page.gd`、`resources/translations/fish_species.csv` 及生成的英文/简体中文翻译资源。
- 航行显示本地化：`scripts/navigation_hud_format.gd`、`scripts/sailboat_navigation_instrument.gd`、`scripts/autopilot_controller.gd`、`scripts/sailboat_auto_reef.gd`、`scripts/sailboat_lab_body.gd`、`scripts/vessel_preview_card.gd`。
- 验证：`tests/test_fishing_p5_1_2_hud.gd`、`tests/test_navigation_hud_format.gd`、`tests/run_s1_c8_integration.gd`。

## 边界

没有改动 P2 鱼群、中鱼概率或 RNG，没有改动 P3 搏鱼/结算，没有改动 P4 扫描几何、回波数据或扫描频率。海况摘要使用现有天气与波浪数据；未新增天气预测或虚构数值。
