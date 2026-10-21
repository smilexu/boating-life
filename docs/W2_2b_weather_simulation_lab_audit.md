# W2.2b 天气生成算法审计与 Weather Simulation Lab 升级

日期：2026-10-20  
Godot：4.7.2  
范围：审计既有 WeatherSimulationCore；升级独立 Lab、统计分析、交互图表与测试。**没有修改 WeatherSimulationCore，也没有接入主场景正式天气或发起网络请求。**

## 结论摘要

- Lab 启动时默认加载的是合成离线 Fixture，不是 MET Norway 缓存。数据源选择和缓存新鲜度现在分开显示。
- 截图里常被看成“193 个预报点”的数字实际是两天时间线的 **193 个生成关键帧**：`2 天 × 24 轮/天 × 4 帧/轮 + 1 个终点`。Fixture 的原始输入只有 12 个不等间隔样本；当前真实缓存有 86 个输入样本。
- 本机存在此前真实 HTTP 200 的 MET Norway 缓存。缓存于 2026-10-20 18:32:09 UTC 获取，服务器缓存截止 19:02:09 UTC；检查时为 20:10:12 UTC，因此状态是 **LIVE CACHE + STALE CACHE**。本次只读了磁盘缓存。
- 算法按真实 UTC 时间戳插值，不按样本序号等权。日汇总风向用风速加权的圆周向量统计；重叠降水窗口按最短有效窗口选择，概率不会伪装成降水量。
- 有一个重要算法限制：雨类状态没有最短持续时长或“当日主导降雨占比”约束。因此如果当天以小雨为主，生成器**不能保证** 24 个游戏日轮中大部分仍被标为降水；报告和 UI 不会宣称有这项保证。本次没有修改生成算法。
- 当前本地 MET 缓存对 2026-10-20 UTC 只覆盖约 18:00–24:00 的 6 小时。选这一天时，Lab 会显示大约 25% 的原始预报覆盖；其它时段为 N/A/不可用，不会拿 Fixture 冒充完整实况。

## A. 天气生成算法审计

### 1. 数据来源、样本含义与 `fresh`

| 项目 | 实际内容 |
|---|---|
| Lab 默认输入 | `tests/fixtures/weather_simulation_two_day_fixture.json`，合成的离线测试数据 |
| Fixture 的原始预报样本 | 12 个，时间范围 `2026-10-20T00:00:00Z` 至 `2026-10-22T00:00:00Z`，间隔包含 1、2、4、5、6 小时 |
| 本机 MET 缓存 | `.godot/weather_live_request_cache/oresund.json`，86 个标准化时间样本 |
| MET 缓存有效范围 | `2026-10-20T18:00:00Z` 至 `2026-10-30T18:00:00Z` |
| MET 缓存间隔直方图 | 54 个 1 小时间隔、31 个 6 小时间隔；并非每个点都是逐小时 |
| 截图中的 193 | 两天、24 轮/天、每轮 4 个生成区间所得的输出关键帧数，不是原始 MET 样本数 |

调用关系：`scenes/WeatherSimulationLab.tscn` → `scripts/weather_simulation_lab.gd::_ready()` → `_load_test_fixture()` → `WeatherSimulationCore.generate_timeline()`。Lab 另有手动“读取真实本地缓存”按钮，它从 `WeatherFileCacheStore` 读取 `.godot/weather_live_request_cache/oresund.json`；Lab 源码不创建 `HTTPRequest`，启动也不会自动刷新网络数据。

本机缓存保留 `provider_id=met_norway_locationforecast_2_0_complete`、MET 源 URL、HTTP 200、预报发布时间 `2026-10-20T18:29:52Z`、获取时间和缓存有效期。这是此前网络请求留在本地的结果；本轮没有重新请求 API。缓存于 19:02:09Z 过期，检查时已过期约 68 分钟。

旧版 Lab 画面中的 `fresh` 是 `WeatherSimulationCore._resolve_data_quality()` 得到的**时间覆盖/数据完整性质量**，不能证明缓存来自在线服务，也不能证明 HTTP 缓存新鲜。新版在顶部单独显示 `LIVE CACHE` / `STALE CACHE`、`TEST FIXTURE` / `N/A · 合成数据` 或 `UNAVAILABLE`。导出的质量报告也增加 `data_source_classification`，区分来源类型、新鲜度以及是否真实在线来源。Fixture 的核心数据质量仍可能为 `fresh`，其含义是请求时间范围内数据覆盖完整，不代表它是真实天气。

原始缓存的 `valid_time_utc` 采样点、发布时间和取回时间都会显示；默认日期为可编辑的 `2026-10-20`，Lab 日期及横轴明确使用 UTC，不暗示它自动跟随本机或游戏内日期。

### 2. 193 点以及非均匀时间样本如何进入计算

`scripts/weather_data/weather_simulation_core.gd::generate_timeline()` 首先由 `_collect_samples()` 合并按 UTC 时间排序的输入样本。它按现实时间日界线与日轮内进度映射生成时间线：

```text
valid_utc = day_start + (cycle_index + cycle_progress) / cycles_per_real_day × (day_end - day_start)
frame_count = day_count × cycles_per_real_day × resolution_per_cycle
keyframe_count = frame_count + 1
```

默认 `resolution_per_cycle=4`。两天、24 轮模式因此得到 193 个输出关键帧；同一请求若只选一天，则 12 轮模式为 49 个关键帧，24 轮模式为 97 个关键帧。193 不是 MET 原始样本数。每个输出帧通过 `_sample_forecast_at()` 根据有效 UTC 时间对实际样本时间插值；遇到超 12 小时的样本间隔时不插值，预报边界最多仅保持 3 小时，之后可变为 `Unknown` / `unavailable`。

日汇总位于 `_build_day_summaries()`：对每两个有效样本之间的字段做线性端点插值，再按实际秒数做梯形积分。它不按样本数算平均；超 12 小时间隔不纳入覆盖。风向汇总 `_time_weighted_direction()` 把方向变成北/东分量，并按风速与区间时长加权，最后用 `atan2` 还原方向。因此 359° 与 1° 会在北向附近合并，而不是错误平均成 180°。

Lab 独立分析器 `scripts/weather_data/weather_simulation_analysis.gd` 同样按实际时间间隔积分。P90 使用时间加权区间中点值，是近似加权分位数，不是连续曲线的精确解析分位数。缺测区间不会补零；超过 12 小时的间隔会从覆盖率和相应统计中排除。

### 3. 12 / 24 日轮映射与日期边界

核心不自行读取系统日历；请求必须明确提供 UTC 开始/结束时间，或提供显式 `real_day_boundaries_utc` 与日标签。

- 24 模式：普通 24 小时 UTC 日中一个游戏日轮映射 1 小时真实预报时间。
- 12 模式：一个游戏日轮映射 2 小时真实预报时间。
- 两种模式沿同一现实天气曲线采样，不是为每个游戏日轮独立抽签。区别是每个日轮代表的现实预报时长和扰动相位间距不同。
- 生成时间线从预报的逐时/逐段变化采样风、云、降水和温度；不是只把“当天平均风速”复制 12 或 24 次。`forecast_day_summaries` 另行提供时间加权日统计。
- 跨午夜时，核心使用请求中连续的 UTC 边界和全局单调 `cycle_offset`。新的一天仍取下一段预报，不在午夜重置噪声相位。数据缺口或预报边界仍可能使字段变成缺测；“边界连续”不等于存在未提供的预报。
- `update_forecast()` 重新生成候选时间线，但只保留经历边界以前的旧帧；边界以后用旧边界状态平滑混合到新预报，默认 1 个日轮。已经经历的片段不会被改写。需要区域、日界线、日轮模式及 cycle→forecast 映射一致，否则返回错误。

**与 `WorldTimeManager` 的关系：**`scripts/world_time_state.gd::DEFAULT_TIME_SCALE` 当前为 24；`scripts/world_time_manager.gd` 的模拟日轮固定 86,400 个模拟秒，日轮增量由单调现实时间差乘 `time_scale` 得到。真实日历使用 Europe/Stockholm 日期，且可有管理员显示日期覆盖；气象日期应取真实日历，不能取覆盖日期。未暂停且倍率为 24 时，名义上对应每现实日 24 个游戏日轮；暂停或改倍率后不再成立。

核心只把 `simulation_anchor.time_scale == cycles_per_real_day` 写成 `nominally_matches_world_time_scale`，且标注“未暂停且倍率不变时有效”。这个布尔值没有验证本地 DST 日界线的时长。核心支持 23/25 小时的 Stockholm 日期边界并仍将它映射到 12/24 个日轮；但当前 WTM 的倍率按固定 86,400 模拟秒累计。因此若 W2.2c 直接把 23/25 小时 Stockholm 日界线与 24 倍 WTM 相连，会存在一天日轮数量和气象日历映射不一致的风险。Lab 使用 UTC 固定 24 小时日，并在内部按所选 12/24 模式构造测试锚点；不会读取或修改 WTM。正式整合前需要决定采用固定 UTC 日，还是调整 DST 日期映射/时间尺度。此次未改 WTM 或核心。

### 4. 风速、风向与阵风

`_sample_forecast_at()` 按 UTC 时间在线性插值样本风速和方向。方向沿最短圆周角插值。平均风低于 0.5 m/s 时，核心沿用前一有效方向，避免静风附近随机跳向。随后 `_make_weather_frame()` 添加由种子和周期偏移计算的低频确定性扰动：

```text
phase_a = seed_phase(seed, 17)
phase_b = seed_phase(seed, 71)
wind_noise  = .62 sin(offset*.77 + phase_a) + .38 sin(offset*.29 + phase_b)
cloud_noise = .65 sin(offset*.51 + phase_b) + .35 sin(offset*.19 + phase_a)
game_wind   = max(0, interpolated_forecast_wind + 0.35 * wind_noise) m/s
game_dir    = forecast_dir + 3 * cloud_noise degrees  (仅 forecast_wind >= 0.5 m/s)
game_cloud  = clamp(forecast_cloud + 0.025 * cloud_noise, 0, 1)
```

扰动由固定种子/时间直接求值，不使用系统随机数或每帧随机重抽；同输入、种子、时间相同。除 0 下限外，平均风速没有额外上限，会保留预报强风；核心只会让它最多增加约 0.35 m/s，不会凭空叠加随机风暴。是否将某个高风速称作极端，核心没有气候阈值定义，质量报告将“无预报依据的极端风”列为 unsupported，而不虚构 pass/fail。

MET 阵风峰值不会原样当作 WindField 噪声振幅。`map_forecast_gust_to_windfield_target()` 的明确映射是：

```text
gust_strength_target = max(0, forecast_gust_mps - generated_mean_wind_mps) × gust_excess_factor
默认 gust_excess_factor = 0.5
默认阵风时间尺度 = 18 s；空间尺度 = 250 m
```

缺失阵风时保持缺省，不以平均风伪造阵风。0.5 是未校准的首版假设；这不是从 MET 预报统计拟合出的物理关系。风速、风向和云量扰动共享确定性低频函数，风速/云量之间具有部分相关；没有单独随机改变的阵风过程。

### 5. 云、降水和天气类型

- 云量直接从 MET `cloud_area_fraction` 转为标准化的 0–1 比例；游戏扰动最多约 ±0.025，再限制到 `[0,1]`。
- `WeatherForecastCodec._read_precipitation_periods()` 保留 `next_1_hours`、`next_6_hours`、`next_12_hours` 各自的开始、结束、时长、降水量和概率。核心 `_precipitation_at()` 在某一时刻选择正在生效的最短窗口；存在降水量时使用 `rate_mm_per_hour = amount_mm / duration_hours`。同一时刻不会把所有重叠周期的毫米数累加。概率独立保留，用于可能降水分类，永远不转成雨量。
- `_read_weather_symbol()` 按 1、6、12 小时顺序取第一个可用 symbol，但标准化数据没有保留该 symbol 来自哪个 forecast window。之后核心取最近 ±3 小时内的 symbol 参与分类。这是时间归属精度损失：6/12 小时窗口的 symbol 可能被当成样本时刻附近的类别信号，而不严格等于该具体时刻的降雨。
- 分类先检查降水量大于零或 symbol 含 rain/sleet/snow，再检查概率 ≥0.55 且云量 ≥0.45 的 `PrecipitationPossible`。其余按云量：`>=0.72` 阴、`>=0.30` 多云、否则晴。类别切换迟滞主要针对云量阈值；真实雨/雪 symbol 或正降水量仍优先。Lab 仅展示核心支持的通用 `Precipitation`，不将其虚构细分成小雨/中雨/大雨。
- 雷暴类别只可能由预报 symbol 中包含 thunder 得到；没有天气生成器主动创建雷暴的规则。现有视觉预设只有 Clear / PartlyCloudy / Overcast，`Precipitation`、`PrecipitationPossible` 和有依据的雷暴类别视觉上会映射为 Overcast。

**“今天以小雨为主时，24 轮能否保证大部分维持阴雨？”不能保证。**当前算法没有日降水占比约束，也没有雨状态最短持续时间。它根据样本周围最多 3 小时内的 symbol、当前有覆盖的预报降水窗口和概率阈值判别类别；晴/阴云类别有阈值滞回，但 precipitation 状态不带有最小持续时间。于是如果小雨只在部分有效预报窗口或 symbol 中出现，剩余轮次可能归为阴天/多云；短时预报窗口也可能令类别切换。核心缺陷记录在此，等待后续明确指令再修。

### 6. 统计质量报告定义

独立分析器 `scripts/weather_data/weather_simulation_analysis.gd` 不写回核心结果：

- 风速均值、云量、降水量均按覆盖小时积分；P90 为覆盖时长加权区间中点 percentile。
- 主导风向为风速加权圆周向量方向，并提供最短有符号角差。
- 雨量按最短有效覆盖窗口积分。降水概率不进入雨量总量；“降水时间占比”是基于预报 symbol/正降水量的信号时长近似，不是雨量观测。
- 天气类别占比、状态切换次数、最长连续降水信号/晴天、最大风速/风向变化率和样本字段缺失比例均按实际覆盖区间统计。样本缺失率按输入点计数，不等于小时覆盖率；两者分别显示。
- Forecast 与 generated 的比较只在所选 UTC 日及源预报有效覆盖内积分；缺失处显示 N/A，不补零。没有未经验证的气候真实性合格阈值。
- `unsupported` 会标出未定义的“无预报依据极端风速阈值”。

## B. Weather Simulation Lab 升级

### 1. 数据源与顶部状态

`scripts/weather_simulation_lab.gd` 的 ` _load_test_fixture()` 默认读取合成 Fixture；`_load_live_cache()` 是显式只读缓存入口。没有缓存时显示 `UNAVAILABLE`，不会偷偷回退 Fixture，也不会自动联网。

顶部控制支持：真实缓存 / Fixture 切换、UTC 日期、随机种子、12 / 24 日轮、重新生成、导出质量 JSON。元数据显示区域坐标、原始样本数、有效时间段、预报发布时间、缓存获取/过期时间、HTTP 状态及样本间隔直方图。Lab 中 12/24 的 time_scale 仅为独立模拟映射，不改 WTM。

### 2. 统计面板与日轮时间线

- 并排展示原始预报统计与游戏生成统计；比较表包括平均风、P90、最大风、主导风向、平均云量、降水信号时长、降水总量及有符号差值。
- 统计卡显示覆盖率、主要天气比例、预报最大阵风、气温/气压范围或状态切换/最长天气连续时长。
- 12/24 横向滚动日轮卡显示编号、主要类别、平均/峰值风、降水信号占比。选择日轮后图表缩放到该区间，并移动统一的日轮游标。
- 点选/拖动图表或游标会更新统一选中时刻。详情同时列出原始预报与生成天气，降水概率仅显示为概率，不写作雨量。

### 3. 三类图表

`scripts/weather_simulation_chart.gd` 使用轻量 Godot `Control._draw()` 绘制，没有第三方图表库：

1. 风速：真实预报风/阵风、游戏平均风、平均风加游戏阵风强度目标，纵轴 m/s。
2. 云量/降水：左轴云量百分比，右轴降水 mm/h，量纲分开。
3. 风向：气象来向、0–360° 真北顺时针；折线用最短角差展开，跨越北向不会画成 358° 的假跳变。

三图有图例、单位和日轮横轴；悬停会画数值 tooltip，详情面板同步当前原始/生成采样。鼠标点击将同一时间设为选中时间。

### 4. UI 缩放与人工验收边界

界面按 ScrollContainer/VBox/HBox 布局，不依赖固定全屏像素位置。自动化布局检查已在 1280×720、1632×957、1920×1080 下验证根滚动区尺寸、图表宽高、24 个日轮卡片、来源标签和选择交互。

**这只是 Godot headless 布局边界验证，不是截图级视觉验收。**没有检查真实窗口中的字体渲染、折线视觉密度、图例挤压或缩放时的实际滚动手感；仍建议用户在可视窗口中检查。

### 5. 质量 JSON 导出格式

按钮将报告写入 `user://weather_simulation_quality_report.json`。实际报告包含 Forecast 与 Generated 的度量、差值、天气占比、覆盖率、字段缺失、连续天气时长、数据提供方与时间线版本。以下是结构节选，`null` 代表当前指标无法比较/覆盖不足，不是零值：

```json
{
  "schema_version": 1,
  "report_type": "weather_simulation_quality",
  "region_id": "oresund",
  "calendar_day_utc": "2026-10-20",
  "source": {
    "provider_id": "offline_weather_simulation_fixture",
    "data_quality": "fresh",
    "issued_at_utc": "2026-10-19T18:00:00Z",
    "sample_count": 12
  },
  "data_source_classification": {
    "source_kind": "TEST FIXTURE",
    "cache_freshness": "N/A · 合成数据",
    "is_live_weather": false
  },
  "comparison": {
    "mean_wind_speed_mps": {"forecast": null, "generated": null, "difference": null},
    "dominant_wind_direction": {"forecast_deg": null, "generated_deg": null, "shortest_signed_difference_deg": null},
    "precipitation_signal_share": {"forecast": null, "generated": null, "difference": null}
  },
  "quality_diagnostics": {
    "forecast_wind_coverage_fraction": 0.0,
    "forecast_missing_field_fraction": {},
    "storm_category_generated": false,
    "unsupported": ["unforecast_extreme_wind_threshold_not_defined"]
  }
}
```

`source.data_quality` 是时间线覆盖质量；`data_source_classification` 才说明 Fixture/缓存类别和缓存新鲜度。上述 null/0.0 是展示结构时使用的占位值；真实导出会填入统计值，不能将示例数值当作当前观测。

## 自动化验证

| 测试 | 结果 |
|---|---:|
| WeatherSimulationCore（原 W2.2b） | 68 项通过 |
| 新增 WeatherSimulationAnalysis | 28 项通过 |
| 新增 WeatherSimulationLab 布局/交互（3 分辨率） | 63 项通过 |
| 新增本地缓存分类/读取（不发 HTTP） | 6 项通过 |
| WindField | 23 项通过 |
| WindFieldLab | 30 项通过 |
| WindField 预设 UI | 8 项通过 |
| Weather / WindField 集成 | 49 项通过 |
| WeatherDataProvider 离线 | 58 项通过 |
| WorldTimeManager | 70 项通过 |
| World time client sync | 45 项通过 |
| Day/night | 155 项通过 |

Headless Lab 场景和 `main.tscn` 均可加载；本轮没有改 `WeatherSimulationCore`，也没有接入主场景天气。自动化测试环境仍输出本机 Godot user:// log 写入失败、macOS CA 证书读取错误，以及 WorldTimeManager 退出时无法保存测试状态的警告；这些在脚本检查之后出现，不是 W2.2b/Lab GDScript parse error。Day/night 测试还报告一个 RendererDummy `DummyShader` RID 清理警告，未追查其来源。真实 GUI 视觉验收和性能测试未完成。

离线运行命令：

```sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tests/test_weather_simulation_core.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tests/test_weather_simulation_analysis.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tests/test_weather_simulation_lab.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tests/test_weather_simulation_lab_cache.gd
```

打开 Lab：

```sh
/Applications/Godot.app/Contents/MacOS/Godot --path . res://scenes/WeatherSimulationLab.tscn
```

## 新增/修改文件

- 新增 `scripts/weather_data/weather_simulation_analysis.gd`：只读统计和质量 JSON 数据模块。
- 新增 `scripts/weather_simulation_chart.gd`：自绘图表、悬停提示与统一时间选择。
- 修改 `scripts/weather_simulation_lab.gd`：数据源、日期/模式、统计对比、日轮、图表、详情与导出。
- 新增 `tests/test_weather_simulation_analysis.gd`、`tests/test_weather_simulation_lab.gd`、`tests/test_weather_simulation_lab_cache.gd`。
- 新增本报告 `docs/W2_2b_weather_simulation_lab_audit.md`；旧 W2.2b 实施报告会链接到本报告以免沿用过期 Lab 说明。

## 未实现/待决

- 未修复雨天持续性或 MET weather symbol 时间窗口丢失；这些属于核心算法变更，依任务要求只记录。
- 未解决 Stockholm DST 本地日历与固定 24×日轮时间的正式映射选择。
- 没有网络请求、实时天气自动刷新、气象生成器对照阈值或 GUI 截图级视觉验收。
- 未修改正式天气行为、WindField、海浪、船舶、WTM 或 W2.2c 接入。
