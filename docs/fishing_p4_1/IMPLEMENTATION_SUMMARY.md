# Fishing P4.1 — 实施摘要

**状态：完成数据接入与针对性验证。** 本阶段扩展已有 `FishFinderSensor`，没有新增第二个鱼群数据源，也没有制作 P4.2 声呐画面。

## 实现

- 传感器由现有 `FishResourceManager` 创建，并继续读取同一份 Authority 学校快照和 `get_schools_near()` 空间索引。
- 默认每秒扫描 3 次。扫描节拍使用单调运行时钟；停船时继续扫描。错过的节拍不会补发扫描突发。手动 `scan(force)` 与 `get_last_scan()`、`get_scan_history()` 保留。
- 每次扫描重新解析当前活动船只。动力船使用其船体变换；帆船模式使用当前帆船刚体变换。探头位置由可调船体局部偏移计算，当前默认 `(0, -0.55, 0)` 米。声束方向保持世界竖直向下，避免船体摇摆带来锥轴跳变。
- 默认半锥角为 10°，先通过 Authority 的空间索引查询宽松候选，再用目标水平距离、垂直深度、锥体半径和斜距逐个做真实几何过滤。
- 使用现有 `BathymetryManager.get_depth_at_world_position()` 读取海图 LAT 水深，使用现有 `WaveSampler.sample_physics_surface()` 读取局部动态水面。无效水深或水面时记录无效扫描，不伪造底部或鱼群回波。
- 每个有效学校最多输出一个聚合回波。强度由学校实际 population、离锥心距离和斜距确定，不使用随机数。回波显示宽度是标记为视觉代理的绘制建议值，不表示 Authority 中的实际群体边界。
- 历史按固定容量淘汰旧列。有效容量至少满足 `scan_frequency_hz × minimum_history_seconds`，默认 180 列、60 秒。对返回结果做深拷贝，调用方修改结果不会改写内部历史。
- F3 Fishing 诊断显示有效状态、扫描时间、探头至底部距离、查询学校数、回波数、历史覆盖和声束配置；原有手动扫描入口保留。新增诊断文案覆盖英文和简体中文。

## 修改文件

- `scripts/fish_finder_sensor.gd`
- `scripts/fishing_debug_panel.gd`
- `resources/translations/fish_species.csv` 及由 Godot 导入生成的英文、简体中文 `.translation`
- `tests/test_fishing_p2.gd`：更新声束配置断言，并检查身份、有效底部和无状态/RNG 副作用
- `tests/test_fishing_p4_1.gd`：新增扫描几何、历史、活动船与无效水深的定向测试

完整字段定义见 [`DATA_CONTRACT.md`](DATA_CONTRACT.md)。
