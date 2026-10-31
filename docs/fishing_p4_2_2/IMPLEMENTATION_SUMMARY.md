# Fishing P4.2.2 实施摘要

## 完成内容

- `FishFinderSensor` 从 Authority School 中心点检测改为确定性空间分布代理与 10° 向下圆锥声束求交。保留 220 m 斜距上限、45 m 最大探测深度和 3 Hz 扫描节奏。
- 每个 School 每列最多输出一个聚合回波。回波携带覆盖/重叠比例、空间代理尺寸及 `ellipsoid_beam_overlap_v1` 方法标记，供 F3 排查。
- 继续通过 `FishResourceManager.get_schools_near()` 空间索引取候选，默认查询半径为 228 m（220 m 探测斜距 + 8 m 最大代理半径）。未遍历 Renderer MultiMesh 鱼实例，也未修改 P2 Authority 或遭遇随机数。
- `FishFinderDisplay` 增加隔离的 Debug Preview 历史。预览复用现有声呐绘制函数，展示固定循环的弱—强—弱聚合回波；可调目标深度、峰值强度与小/中/大规模档位。
- F3 → Fishing 新增声呐回波预览的启动、停止和参数控件。预览开启时打开鱼探仪并显示醒目的 `SONAR PREVIEW / 声呐预览` 标签；停止后立即恢复真实传感器历史。
- 两种语言的 F3 几何原因和预览文案已加入现有翻译表。

## 主要修改

- `scripts/fish_finder_sensor.gd`
- `scripts/fish_finder_display.gd`
- `scripts/fishing_debug_panel.gd`
- `resources/translations/fish_species.csv` 及导入生成的翻译资源
- `tests/test_fishing_p4_1.gd`
- `tests/test_fishing_p4_2.gd`
- `tests/test_fishing_p2.gd`
- `tests/test_surface_fish_visibility.gd`

具体的代理定义和限制见 [SCHOOL_VOLUME_MODEL.md](SCHOOL_VOLUME_MODEL.md)。
