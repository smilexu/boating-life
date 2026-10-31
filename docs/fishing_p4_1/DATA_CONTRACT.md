# Fishing P4.1 — 扫描数据契约

接口位于 [`FishFinderSensor`](../../scripts/fish_finder_sensor.gd)。扫描列和回波以 `Dictionary` 表示，供 P4.2 直接绘制；UI 不必再次访问 Authority 内部数据。

## 单条扫描列

`get_last_scan()` 返回最近一列，`get_scan_history()` 按时间从旧到新返回有界历史。两者均返回深拷贝。

| 字段 | 类型 | 定义 |
|---|---|---|
| `accepted` | bool | 本次扫描是否执行并记录；节流拒绝的手动调用返回 `accepted=false`，不会产生新列 |
| `valid` | bool | 此列是否具有有效探头、海图底部及水面基准；有效空水列仍为 true |
| `reason` | String | 有效为 `ok`；无效列包含依赖、海图、水面或几何错误原因 |
| `scan_id` | int | 本传感器单调递增列序号 |
| `scan_runtime_seconds` | float s | Godot 单调运行时刻，供滚动和间隔计算使用；不受世界时间倍率影响 |
| `scan_game_time_seconds` | float s | 现有 WorldTime/Authority 游戏时间，供后续游戏内时间语义使用，不驱动扫描节拍 |
| `scan_unix_time_seconds` | float s | 系统 Unix 时间，便于诊断/日志对照 |
| `active_vessel_id` | String | 当前活动船身份；优先船型资源 ID，否则由场景/节点名生成 |
| `boat_speed_mps` | float m/s | 当前船速；动力船读取控制器速度，帆船读取刚体线速度大小 |
| `scan_origin_world_position` | Vector3 m | 船体局部偏移变换后的换能器世界位置；为便于消费者理解，也写入兼容字段 `probe_world_position` |
| `bathymetry_valid` / `surface_valid` / `bottom_valid` | bool | 三种参考数据的独立有效性 |
| `chart_depth_lat_m` | float m | 从海图 LAT 基准面向下的正水深；无效时为 -1 |
| `surface_height_world_y_m` | float m | 同一世界坐标系中的实时局部水面 Y |
| `seabed_world_y_m` | float m | `chart_datum_world_y_m - chart_depth_lat_m` 得出的海底世界 Y |
| `water_column_below_surface_m` | float m | 动态水面 Y 减海底世界 Y；无效时为 -1 |
| `bottom_depth_below_transducer_m` | float m | 换能器 Y 减海底 Y；无效时为 -1 |
| `effective_detection_depth_range_below_transducer_m` | Vector2 m | 此列可检测的垂直深度范围；有效时从 0 到当前底部/最大范围裁切值 |
| `query_radius_m` | float m | 送入 Authority 空间索引的粗查询半径，当前为最大斜距 |
| `beam_half_cone_angle_deg` | float ° | 半锥角，默认 10° |
| `max_slant_range_m` | float m | 声束斜距上限，默认 220 m |
| `scan_frequency_hz` | float Hz | 当前目标频率，默认 3 Hz |
| `schools_considered_count` | int | 空间索引返回的候选学校数 |
| `schools_detected_count` | int | 几何、水深和种群过滤后生成的聚合回波数 |
| `echoes` | Array[Dictionary] | 本扫描列新检测到的学校聚合回波；空数组表示本列没有检测到鱼群 |

坐标约定：世界 Y 向上，水深字段向下为正。海图水深基于 LAT；动态水面高度、换能器位置和海底世界 Y 都在世界坐标中。鱼群活动深度 `activity_depth_m` 表示从当前局部水面向下的深度，目标 Y 由 `surface_y - activity_depth_m` 得出。鱼群海底净空以该位置与同处海底 Y 的差计算。

## 单个鱼群聚合回波

每个学校在一列内至多产生一条回波，不逐鱼生成声呐目标。

| 字段 | 类型 | 来源/用途 |
|---|---|---|
| `echo_id` | String | 本列 ID 与 `school_id` 的组合；仅在当前扫描列内标识 |
| `school_id` | String | 稳定 Authority 鱼群身份，内部数据 |
| `species_id` | String | 稳定鱼种 ID，供开发诊断；正式传统声呐 UI 不应据此显示鱼种 |
| `target_world_position` | Vector3 m | 使用鱼群水平锚点及实时水面/活动深度构造的目标中心 |
| `relative_position_m` | Vector3 m | 目标中心相对换能器的位置 |
| `target_depth_below_transducer_m` | float m | 目标中心相对换能器的垂直深度，向下为正 |
| `depth_below_surface_m` | float m | Authority 活动水层深度，向下为正 |
| `slant_range_m` / `horizontal_offset_m` | float m | 斜距 / 水平偏移实际距离 |
| `beam_radius_m` | float m | 此目标深度处半锥几何覆盖半径：`depth × tan(half_angle)` |
| `beam_center_fraction` | float 0–1 | 水平偏移占该深度锥半径的比例；0 为中心、1 为边缘 |
| `group_population` | int fish | Authority 当前学校的真实鱼数 |
| `group_intensity` | float 0–1 | 确定性规模指标：`1 - exp(-population / 8)` |
| `echo_strength` | float 0–1 | 规模指标乘以离锥心和斜距衰减；Gain 可在 UI 端仅改变绘制，不应改底层检测 |
| `echo_width_m` | float m | `sqrt(population) × 0.22` 后裁切到 0.25–2.5 m 的显示建议值 |
| `echo_width_is_visual_proxy` | bool | 当前固定 true，说明宽度是绘制代理，不是测得的真实群体跨度 |
| `estimated_group_size_band` | String | 仅供粗略绘制：≤3 small、≤10 medium、其余 large |
| `activity_state` | String | Authority 学校当下活动状态；不是鱼种识别结果 |

强度没有随机扰动，因此同一群体、数量和几何条件会得到相同值，不消耗 P2 遭遇 RNG。P2 Authority 只提供学校锚点、population 和活动水层，不提供每条鱼的空间分布/群体包络，所以当前无法计算真实声学反射或群内真实宽度。

## 几何、节拍和历史

- 候选来自现有 `get_schools_near(probe, max_slant_range_m)` 空间查询；随后再次用锥半径、真实水平距离、垂直距离、斜距、实时水面、活动水层和海底净空过滤。声束轴保持世界竖直向下，不随船体 roll/pitch 倾斜。
- 每个学校的垂直深度 `d` 对应声束半径 `d * tan(half_cone_angle)`。最大垂直范围受当前底距、最大水深及最大斜距约束。
- 默认 3 Hz 扫描每 0.333 秒最多产生一列。节拍使用单调运行时；停船不暂停扫描。引擎卡顿后只采一列，不补发多列。
- 历史容量为 `max(history_capacity, ceil(scan_frequency_hz * minimum_history_seconds))`，并限制在 1–12000 列。默认 180 列，覆盖至少约 60 秒。旧列先进先出淘汰；每列保留采样时刻自己的海底深度与回波。
- 无效扫描也记录并发出 `scan_completed`，其 `valid=false`、回波为空、深度哨兵为 -1；有效但无鱼列 `valid=true` 且回波为空。
- 手动 `scan(force=true)` 立即产生一列并重置自动节拍；旧 `scan()`、`get_last_scan()`、`get_scan_history()` API 保留。

## 数据边界

真实值：当前船/探头位置、船速、海图 LAT 水深、WaveSampler 水面、Authority 学校 ID/鱼种 ID/population/活动深度、扫描时刻。

可视化推导：回波强度、群体大小档、`echo_width_m`、声束中心比例、回波目标中心世界坐标。推导值只服务声呐绘制，不改变鱼群、Encounter、鱼数或咬钩概率。
