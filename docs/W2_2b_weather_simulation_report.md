# W2.2b：现实天气驱动的游戏天气生成器报告

日期：2026-10-20  
Godot：4.7.2  
范围：天气时间线生成核心、离线测试与独立查看场景；没有接入主场景自动天气。

> **更新提示（2026-10-20）**：本文“云、降水和天气类型”中关于天气符号没有保留预报窗口的描述，是 W2.2b 初版的历史状态，已由 [W2.2b.1 降水时间语义修正与天气持续性优化](W2_2b_1_precipitation_semantics_and_persistence.md) 修正。当前 Codec 使用标准化 schema v2，保留 MET `next_1/6/12_hours` 天气符号和降水窗口。本文其余内容仍记录 W2.2b 初版架构，不应覆盖新报告中的降水语义与最新测试结果。

## 交付内容

- `scripts/weather_data/weather_simulation_core.gd`：纯数据天气时间线生成、采样、序列化和预报更新逻辑。
- `scripts/weather_data/weather_simulation_core_contract.gd`：扩展生成请求和时间线数据契约；保留 W2.2a 原请求/输出验证入口。
- `scenes/WeatherSimulationLab.tscn`、`scripts/weather_simulation_lab.gd`：离线时间线查看器，提供 12/24 昼夜、种子、时间游标、风速/云量曲线和状态采样。
- `tests/fixtures/weather_simulation_two_day_fixture.json`：两天、非均匀采样的合成预报夹具，不代表实测天气。
- `tests/test_weather_simulation_core.gd`：W2.2b 确定性离线测试。

未修改 `WorldTimeManager`、主场景正式天气、WindField 算法、海浪、船舶或昼夜系统。W2.2a 的天气 API Provider 没有被调用；本阶段没有新的在线天气请求。

## WorldTimeManager 审计与映射规则

当前实现位于 `scripts/world_time_manager.gd` 和 `scripts/world_time_state.gd`：

- 一个游戏昼夜固定为 86,400 个日轮秒。
- 日轮推进量为现实单调时钟间隔乘以 `time_scale`。默认倍率为 24：在未暂停且倍率不变时，每现实小时约走完一个游戏昼夜，每现实日约 24 轮。倍率 12 时约为每天 12 轮。
- `pause_time()` 只停止游戏日轮；真实 UTC/Stockholm 日期仍继续更新。管理员日期覆盖只改显示日期，不改 `real_calendar_date`。
- `day_cycle_index` 和 `cycle_seconds` 是日轮权威位置。启动时日轮相位不保证与现实午夜对齐；本实现通过权威 UTC 锚点计算它在预报日内的位置。
- 因倍率可在运行时修改、暂停也会冻结日轮，实际每现实日循环数只在倍率匹配且未暂停时符合 12/24 设置。核心在生成结果中写入 `world_time_mapping.nominally_matches_world_time_scale`；不匹配时会保留事实并给出标记，不会擅自修改管理器。

核心时间接口以 `day_cycle_index + cycle_seconds` 采样。生成请求需提供 `simulation_anchor`，可用 `WeatherSimulationCore.make_simulation_anchor_from_world_time_snapshot(snapshot)` 从 WorldTimeManager 权威快照转换。`sample_weather()` 的 `elapsed_cycles` 是相对该锚点的日轮偏移。

天气预报时间区间默认按完整 UTC 日处理。为了与 WorldTimeManager 的 Stockholm 日期吻合，契约还支持显式 `real_day_boundaries_utc`、`calendar_day_labels` 和 `calendar_boundary_basis`。Godot 适配层应把每个 Stockholm 本地午夜转换成 UTC 边界后传入。这样可正确表示夏令时的 23 小时和 25 小时日；核心不读取本地时钟或系统时区。自动接入时应从 `get_real_utc_timestamp()` / `get_real_calendar_date()` 选真实预报日期，不要把管理员显示日期覆盖当成气象日期。

## 生成算法

### 预报数据和每日背景

`generate_timeline(request)` 接受 W2.2a 标准化文档（单份 `forecast_document` 或多份 `forecast_documents`），不依赖 MET Norway 原始 JSON。

- 每个预报字段按其真实 UTC 时间戳定位；不等间隔采样通过实际时间差插值。
- 每日风速、阵风、云量、温度、气压和湿度背景用梯形积分按时间加权，并附字段覆盖率。风向用风速加权圆周平均。
- 日汇总保留预报天气符号样本和原始降水统计窗口。降水窗口不会把 1/6/12 小时数据混成同一个量。
- 点采样时，在覆盖该时刻的降水窗口中优先选择持续时间最短的窗口；如果有降水量，输出 `mm/h = amount_mm / duration_hours`，并保留原量、窗口和概率。

### 连续时间线与确定性

一个预报日映射到配置的 12 或 24 个游戏日轮。默认每 0.25 个日轮生成一个关键帧；`sample_weather()` 在关键帧间插值连续字段，风向使用最短角度路径。低于 0.5 m/s 时保持邻近预报风向，避免静风时方向无意义旋转。

同一预报、请求元数据、随机种子和权威时间锚点会产生一致的 JSON 时间线。轻微扰动只使用种子和时间偏移计算的连续低频正弦项：风速最多约 ±0.35 m/s、风向约 ±3°、云量约 ±0.025；没有系统墙钟、调用次数或可变 RNG 状态参与。

天气分类由预报驱动：降水量/湿天气符号产生 `Precipitation`；较高降水概率且云量较高时输出 `PrecipitationPossible`；其余依据云量分为 `Clear`、`PartlyCloudy`、`Overcast`。相邻分类采用不同进入/退出阈值，抑制低频扰动让云量恰好在阈值附近时反复切换；明确的降水符号或降水量仍优先。输出兼容现有视觉预设 ID；降水映射到 `Overcast`。没有独立抽签、凭空造雷暴或把强风自动升级为风暴。连续气象字段平滑，类别 ID 是离散标签，W2.2c 应通过现有 WeatherStateController 过渡接口做视觉淡入。

### 风况和缺失数据

- 风速输出为 m/s，风向为真北顺时针的气象来向；没有转换成空气流动去向。
- MET 预报的阵风是峰值，不能直接当作 WindField 的附加阵风幅度。当前明示的首版映射是 `max(0, forecast_gust - mean_wind) * 0.5`。0.5 系数尚未物理校准，可通过请求配置覆盖。另有可配置默认时间尺度 18 s、空间尺度 250 m；这些是游戏模型参数，不是 MET 观测值。
- 缺失湿度、阵风、降水等字段会保持缺省。超出预报覆盖或间隔过大时对应状态可能 unavailable；源数据质量区分 `fresh`、`stale`、`partial`、`stale_partial`、`unavailable`。陈旧缓存不会被标为 fresh；完全不可用时不伪造风速/云量。
- 时间线记录区域、提供方、预报发布时间/检索时间、有效范围、来源元数据、生成时间、日界线、种子、时间线版本和权威时间锚点。

### 预报更新

`update_forecast(old_timeline, new_request, preserve_through_cycle_offset, blend_cycles)` 保留已经历边界之前的旧关键帧，边界处采用旧状态，未来在默认 1 个游戏日轮内向新预报平滑过渡。更新要求区域、日期边界、日轮模式与“游戏日轮位置到预报时间”的映射一致；如果暂停或倍率变化造成映射变化，返回 `simulation_time_mapping_changed`，由 W2.2c 决定恢复后更新或执行显式重新锚定。这样不会悄悄重写已经经历的天气历史。

## 时间线 JSON 示例

以下是合成离线夹具的一条精简关键帧示例，数字仅用于说明格式，不是实测天气：

```json
{
  "schema_version": 1,
  "timeline_version": "simulation_24_177:177",
  "region_id": "oresund",
  "provider_id": "offline_weather_simulation_fixture",
  "source_data_quality": "fresh",
  "forecast_issued_at_utc": "2026-10-19T18:00:00Z",
  "real_start_utc": "2026-10-20T00:00:00Z",
  "real_end_utc": "2026-10-22T00:00:00Z",
  "cycles_per_real_day": 24,
  "simulation_seed": 177,
  "simulation_anchor_timeline_cycle_offset": 0.0,
  "keyframe": {
    "cycle_offset": 0.0,
    "valid_time_utc": "2026-10-20T00:00:00Z",
    "game_day_cycle_index": 36,
    "day_cycle_progress": 0.208333,
    "mean_wind_speed_mps": 5.1563,
    "wind_from_direction_deg": 359.338,
    "gust_forecast_mps": 7.0,
    "gust_target": {
      "gust_strength_mps": 0.9219,
      "time_scale_seconds": 18.0,
      "space_scale_meters": 250.0,
      "calibration_status": "uncalibrated_first_pass_assumption"
    },
    "cloud_fraction": 0.8512,
    "precipitation_intensity_mm_per_hour": 0.0,
    "weather_type": "Overcast",
    "visual_weather_id": "Overcast"
  }
}
```

实际时间线用 `keyframes` 数组保存所有采样点；上例把数组简写成单个 `keyframe` 便于阅读。完整 JSON 可由 `serialize_timeline()` 导出，`deserialize_timeline()` 会验证 schema。

## WeatherSimulationLab

Lab 后续已扩展为手动切换合成 Fixture 与 MET Norway 本地缓存的只读查看器，并增加真实预报/生成天气统计、日轮时间线、风速/云量降水/风向图、hover 详情及质量 JSON 导出。启动默认 Fixture，不会联网；Fixture 的 freshness 显示为 N/A。完整算法审计、缓存时间与 UI 说明见 [W2.2b_weather_simulation_lab_audit.md](W2_2b_weather_simulation_lab_audit.md)。

运行方式：

```sh
/Applications/Godot.app/Contents/MacOS/Godot --path . res://scenes/WeatherSimulationLab.tscn
```

或在 Godot 编辑器中打开 `WeatherSimulationLab.tscn` 并运行当前场景。

## W2.2c 接入建议

正式适配仍未启用。建议的权威端流程：

1. WeatherDataProvider 返回 `fresh/stale/unavailable` 和标准化文档；客户端不直接请求第三方服务。
2. 权威端用当前 WorldTimeManager 快照生成 `simulation_anchor`，并传入匹配的日轮倍率、UTC 预报日界线（Stockholm 本地日则传显式边界/标签）及显式 `generated_at_utc`。
3. 权威端只生成一次时间线并序列化广播：region、timeline version、seed、权威时间锚点、预报元数据和关键帧。
4. 服务端与客户端都以权威 `day_cycle_index/cycle_seconds` 调用纯采样；客户端只插值显示，不另行取天气或生成随机结果。
5. 把采样结果映射为 `WeatherWindProfile` 等数据后交给 `WeatherStateController.apply_climate_weather_target()`。F12 仍作为本地覆盖，不写入正式权威状态。

当前需要在 W2.2c 决定的事项：倍率与 12/24 模式不匹配时是否拒绝激活；天气在 `pause_time()` 期间是否冻结；倍率改变/暂停后缓存刷新如何重锚；如何将湿度、降水概率和温度映射到未来视觉效果；天气时间线与世界日期存档如何共同持久化。不要从 `calendar_date` 管理员覆盖读取真实气象日期。

## 测试与验证

W2.2b 自动化测试：**68 项通过**，含 12/24 映射、确定性、种子差异、低风/风向跨北、阈值附近天气类别稳定性、晴天/阴雨/强风约束、降水/云量、非均匀间隔时长加权、缺失阵风、stale/unavailable、跨午夜、23/25 小时 Stockholm 日界线、更新保留历史、JSON 往返及权威时间采样。

回归测试：

- WindField：23 项通过。
- WindFieldLab：30 项通过。
- WindField 预设 UI：8 项通过。
- Weather/WindField 集成：49 项通过。
- WeatherDataProvider 离线：58 项通过。
- WorldTimeManager：70 项通过。
- World time client sync：45 项通过。
- Day/night：155 项通过。

场景检查：WeatherSimulationLab headless 加载通过；`main.tscn` headless 加载通过。当前 Lab 的来源/算法审计与 UI 自动化结果见 [W2.2b_weather_simulation_lab_audit.md](W2_2b_weather_simulation_lab_audit.md)。Godot 测试退出时仍可见的 DummyShader RID 警告尚未单独追查；没有完成截图级 GUI 视觉验收或性能测试。

单独运行 W2.2b 测试：

```sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tests/test_weather_simulation_core.gd
```

## 未完成范围

- 本轮未访问真实 MET Norway API；W2.2b 全部测试使用合成离线数据。
- 未更改 WorldTimeManager 的默认倍率、暂停或日期规则。
- 未启用真实天气、未应用到主场景，也未实现多人传输、天气存档、降雨视觉或 W2.2c。
- 阵风峰值到 WindField 强度的比例仍需之后通过船舶/海面响应校准；本阶段没有改 WindField 算法。
