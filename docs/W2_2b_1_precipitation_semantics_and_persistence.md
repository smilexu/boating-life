# W2.2b.1：降水时间语义修正与天气持续性优化

日期：2026-10-20  
Godot：4.7.2  
范围：标准化预报 Codec、纯数据天气时间线、只读分析器、Weather Simulation Lab 诊断和离线测试。没有接入主游戏正式天气，也没有修改 WindField、WorldTimeManager、海浪、船舶或 F3/F12。

## 结论

- MET Norway 的 `next_1_hours`、`next_6_hours`、`next_12_hours` 是从对应 timeseries `time` 向前的聚合窗口。标准化 schema 已升级到 v2，天气符号与降水字段各自保留窗口起止、时长和来源字段。
- 对覆盖同一时刻的多个窗口，符号、雨量、降水概率分别独立选取最短的有效窗口；同分辨率时选起点较新的窗口。窗口按 `[start, end)` 生效，结束点不会多算一个小时。
- 重叠降水窗口不相加；降水概率不转换为雨量。窗口雨量除以窗口时长只作为均匀分布假设下的平均强度估算，并以该速率对有效覆盖时段积分。
- 天气“持续性”现在以真实窗口的有效时间范围为准：连续小雨不会因游戏日轮采样点改变而闪断，短时阵雨也不会被扩展到窗口以外。没有硬编码雨天占比或最短降雨时长，也不会为了平滑而越过已知降水起止边界。
- Lab 现在分别显示全天内有证据的降水比例、降水证据时段条件占比、窗口覆盖率与分辨率。未覆盖时间保持未知，不会被默认为无雨。
- 核心可接受显式 Stockholm 日界线并正确映射 23/25 小时日，但它不自行查询时区数据库或将本地日期转换为 UTC。生成调用方必须传入 `Europe/Stockholm` 标签、当地日历日期标签和准确 UTC 边界；Lab 仍是明确标记的 UTC 日期诊断工具。此转换留给之后的适配层处理。

## MET Norway 时间窗口语义

本次按 MET Norway 官方格式文档核对字段语义：时间序列时间戳统一为 UTC；序列分辨率可以由 1 小时变为 6 小时；`next_X_hours` 里的降水量是从当前 timeseries `time` 开始的区间聚合值；`symbol_code` 描述对应时间段；数据末端可能只有 `instant` 而没有 period 字段。见 [MET Norway General point forecast JSON format](https://api.met.no/doc/ForecastJSON) 与 [Locationforecast data model](https://docs.api.met.no/doc/locationforecast/datamodel.html)。

### schema v2 的标准化结构

`scripts/weather_data/weather_forecast_codec.gd` 的 `parse_met_response()` 现在分别标准化两类窗口：

```json
{
  "schema_version": 2,
  "timeseries": [
    {
      "valid_time_utc": "2026-10-20T12:00:00Z",
      "precipitation_periods": [
        {
          "duration_hours": 1,
          "period_start_utc": "2026-10-20T12:00:00Z",
          "period_end_utc": "2026-10-20T13:00:00Z",
          "source_period_key": "next_1_hours",
          "source_field": "details.precipitation_amount/probability",
          "source_fields": [
            "details.precipitation_amount",
            "details.probability_of_precipitation"
          ],
          "precipitation_amount_mm": 0.2,
          "precipitation_probability": 0.0
        }
      ],
      "weather_symbol_periods": [
        {
          "duration_hours": 6,
          "period_start_utc": "2026-10-20T12:00:00Z",
          "period_end_utc": "2026-10-20T18:00:00Z",
          "symbol_code": "rain",
          "source_period_key": "next_6_hours",
          "source_field": "summary.symbol_code"
        }
      ]
    }
  ]
}
```

这里只示意字段结构，不代表当天真实天气。字段在原始响应缺失或不是有限数值时不写入。`source_fields` 只列出实际存在的雨量和/或概率字段。

Codec v2 校验：

- 每个窗口的起点必须等于其来源 timeseries 样本时间；终点必须等于起点加 `duration_hours`。
- 只接受当前支持的 1/6/12 小时窗口，且来源键必须与时长一致。
- 符号和降水值独立记录来源，不用符号窗口时长推断降水量时长，反之亦然。
- v2 不允许含糊的单点 `weather_symbol` 字段。

### 有效窗口选择

核心 `WeatherSimulationCore._weather_symbol_at()` 与 `_precipitation_at()` 检查当前 UTC 时刻是否位于半开区间 `[period_start_utc, period_end_utc)`。窗口重叠时分别选择：

1. 符号：最短的有效 symbol 窗口。
2. 雨量：最短的、且确实带有 `precipitation_amount_mm` 的有效窗口。
3. 概率：最短的、且确实带有 `precipitation_probability` 的有效窗口。

同一个短窗口如果只有概率而没有雨量，不会遮蔽仍有效的较长雨量窗口。相同窗口长度时选开始时间较新的窗口。核心将窗口起止加入关键帧位置，使状态在有效边界变化，而不是等到固定采样点才改变。

### 降水量统计

当选中窗口有累计量 `A mm`、持续 `D hours` 时，统计器使用 `A / D mm/h` 作为该窗口的**平均速率估算**。对每段有效覆盖时长 `Δt` 积分 `rate × Δt`。这既不会把重叠的 1/6/12 小时累计量相加，也不会把概率乘成雨量。

这是区间平均估计，不是窗口内逐分钟雨强曲线；MET 只给出聚合窗口时，不能从单个累计值恢复真实降雨在窗口内的起伏。分析结果同时报告窗口分辨率与雨量字段覆盖率，区间粗或覆盖不足时不宣称是逐小时降雨事实。

## 旧 schema 兼容

- 标准化预报 Codec 保持读取 schema v1 和 v2。`deserialize_document()` 会将 v1 文档升级到 v2；v1 中已有的显式降水窗口会补齐对应来源元数据。
- v1 单点 `weather_symbol` 不含可恢复的时间区间。迁移时改名为 `legacy_weather_symbol` 并标记 `unknown_window_not_used_for_duration`，只用于兼容显示，不用于时间加权天气分类；迁移过程不会猜测 1/6/12 小时窗口。
- 当前生成时间线 schema 仍为 v1。新增的符号/雨量/概率窗口诊断字段为可选项，旧时间线缺少这些字段仍可读取；未知时间线 schema 仍会拒绝。
- 若直接把 v1 文档传给分析或生成入口，旧单点符号同样只按兼容字段处理，不会把它延长成持续天气。

## 现实日天气背景统计

`WeatherSimulationAnalysis._analyze_series()` 将预报样本时间、符号窗口边界、降水窗口边界和所选日期边界合并为有序区间。对每个区间取中点，按照该时刻有效窗口选择规则分类，然后按区间实际 UTC 秒数累计，不按采样点数量平均。

统计结果将天空状态和降水状态分成两个相互独立的维度：

| 统计内容 | 定义 / 分母 |
|---|---|
| 晴朗 / 多云 / 阴天占比 | 有天空状态分类证据的有效小时；三种天空状态是独立天空统计，不与降水状态互斥。 |
| 明确降水 / 可能降水状态时长占比 | 有降水窗口或天气符号证据的有效小时。 |
| `explicit_precipitation_day_fraction` | 已确认明确降水的小时 ÷ 所选现实日完整小时。未覆盖时间不补作干燥或降雨，因此覆盖不完整时这是“当天已证实部分”，不能当成整日外推比例。 |
| `possible_precipitation_day_fraction` | 有概率依据、但不是明确降水的小时 ÷ 所选现实日完整小时。仍与明确降水分开。 |
| `precipitation_evidence_coverage_fraction` | 有符号/降水时间窗证据的小时 ÷ 所选现实日完整小时；状态为 `complete`、`partial` 或 `unavailable`。 |
| 预报总降水估算 | 在有雨量数值的有效覆盖窗口上积分平均雨强；没有雨量时为 `null`。 |
| 平均 / 最高雨强 | 分别为雨量覆盖时段的时间加权平均速率和选中窗口平均速率最大值。没有雨量数值时为 `null`。 |
| 最长连续明确降水 / 可能降水 | 只跨越连续、相邻且有证据的区间；未知覆盖会断开连续长度。 |
| 降水分辨率 | 实际参与分类的窗口最小、最大及时间加权平均时长。 |

`precipitation_probability >= 0.55` 是当前项目为了“可能降水”类别采用的启发阈值，不是 MET Norway 的官方降雨分级。天气符号保留 `rain`、`sleet`、`snow`、`thunder` 原类型；没有新增小雨/大雨强度等级，也没有把概率说成已发生降水。

## 游戏天气持续性与边界行为

本轮持续性基于**实际预报有效区间**，不重新洗牌预报状态，也不加入人为的最短雨程：

- 持续阴雨：连续的湿天气符号或正降水窗口会在 12/24 日轮模式下保持显式降水状态。云量类别有阈值迟滞以防小扰动闪烁；明确的降水状态不被这个迟滞覆盖。
- 短时阵雨：只在半开区间内判为明确降水。开始时刻不向前扩展，结束时刻不向后延长。
- 持续晴天：没有降水/湿天气符号证据时，仍按预报云量与符号分类，不抽签制造降水。
- 现实 00:00 UTC 跨日：时间线使用连续的 UTC 区间，窗口开始/结束边界被纳入关键帧；连着午夜的两个相邻雨窗会合并为连续降水时长。预报缺口不会填入虚构天气。
- 新预报修订：核心已有 `update_forecast()` 历史保留机制；已经历的关键帧不会被新预报改写，未来从更新边界向新预报平滑过渡。该行为有回归测试，本轮没有引入新重生成器。

本轮的三种专项对照（全部使用离线合成夹具）：

| 情形 | 预报背景统计 | 生成时间线结果 | 结论 |
|---|---:|---:|---|
| 持续小雨/明确降水，24 小时覆盖 | 明确降水 24/24 h（100%） | 12 轮和 24 轮均为 24/24 h；最长连续明确降水 24 h | 全天背景保留，无日轮边界闪断。 |
| 单小时阵雨，其余时间无明确降水 | 1/24 h（约 4.17%） | 24 轮仍为 1/24 h；窗口前后样点均不延长雨状态 | 没有为了“持续性”扩宽降水边界。 |
| 持续晴天夹具 | 无湿天气符号、低云量 | 保持 Clear；没有凭空加入雨或风暴 | 固定种子只引入已定义的小幅连续扰动。 |

这些是明确定义的测试夹具，不是对 MET Norway 当天实况的报告。不同种子不会重排预报天气或更改已知降水窗口。

## 12/24 日轮与 Stockholm 日期边界

天气核心不读系统时钟、场景树或 WorldTimeManager。调用方显式传入：

- `requested_start_utc`、`requested_end_utc`。
- `real_day_boundaries_utc`：每个现实当地日的 UTC 开始/结束边界。
- `calendar_day_labels`：与每个边界区间对应的当地日历日期。
- `calendar_boundary_basis`：例如 `Europe/Stockholm`。
- 12 或 24 个 `cycles_per_real_day`、预报文档、种子与权威时间锚点。

每个当地日的 UTC 时长 `T` 可以是 23、24 或 25 小时；核心把当天实际 `[start,end]` 线性映射到固定 12/24 轮，不改 WorldTimeManager 的运行倍率。自动时区规则转换不在纯数据核心里完成。没有显式边界的历史调用仍使用固定 UTC 整日，以兼容旧请求；未来权威天气调用应以 Stockholm 当地日为默认选择，并由适配层提供准确 UTC 界线。

离线验证结果：

- 2026-03-29 Stockholm 春季切换：`2026-03-28T23:00Z` 至 `2026-03-29T22:00Z`，23 小时；24 轮模式的第 12 轮映射到 `10:30Z`。
- 2026-10-25 Stockholm 秋季切换：`2026-10-24T22:00Z` 至 `2026-10-25T23:00Z`，25 小时；24 轮模式的第 12 轮映射到 `10:30Z`。
- 两种模式的非 DST 日期映射和 12/24 轮确定性测试通过。

## Weather Simulation Lab 变化

保持原有页面、三类图表和分辨率布局，本轮仅加诊断信息：

- 比较表分别显示“明确/可能降水占全天（只计已知时段）”与“明确/可能降水占降水证据时段”，并提供生成值与差值。
- 汇总卡显示降水证据覆盖状态和比例、有效窗口分辨率范围、最长连续明确/可能降水、天气状态切换次数。
- 选中时刻显示分类依据以及符号、雨量、概率窗口的来源和有效起止。
- 明确告知概率不换算雨量、未覆盖时间不视为干燥。
- `TEST FIXTURE`、真实本地缓存的 `LIVE CACHE` / `STALE CACHE` 与 `UNAVAILABLE` 仍区分显示；数据覆盖完整不代表缓存新鲜。
- Lab 默认仍为测试 fixture，并且不会在启动时发起 HTTP 请求。界面日期目前标为 UTC，Stockholm 当地日期到 UTC 边界的转换留待适配层处理。

质量报告 JSON 的相关结构（值由实际离线数据统计，以下以 `null` 表示无数据的结构示意）：

```json
{
  "schema_version": 2,
  "weather_background_retention": {
    "precipitation_comparison": {
      "explicit_precipitation_day_fraction": {
        "forecast": null,
        "generated": null,
        "difference": null
      },
      "possible_precipitation_day_fraction": {
        "forecast": null,
        "generated": null,
        "difference": null
      }
    },
    "forecast": {
      "sky_condition_time_share_percent": {},
      "precipitation_state_time_share_percent": {},
      "precipitation_window_coverage_fraction": 0.0,
      "precipitation_time_resolution_mean_hours": null
    },
    "generated": {},
    "classification": "time-weighted forecast-window estimates; uncovered time is unknown"
  }
}
```

完整报告还保留风/云统计、缺失字段比例、窗口覆盖、时序分辨率、状态占比和来源质量，用于后续 JSON 导出分析。

## 修改文件

- `scripts/weather_data/weather_forecast_codec.gd`：标准化 schema v2、窗口解析/校验、v1 兼容迁移。
- `scripts/weather_data/weather_simulation_core.gd`：窗口边界关键帧、符号/雨量/概率独立窗口选择及输出诊断字段。
- `scripts/weather_data/weather_simulation_core_contract.gd`：验证新增的可选窗口元数据，同时保持旧时间线可读。
- `scripts/weather_data/weather_simulation_analysis.gd`：时间加权背景统计、覆盖率、分辨率、持续时间和降水比较报告。
- `scripts/weather_simulation_lab.gd`：降水日比例与证据时段占比诊断。
- `tests/fixtures/weather_simulation_two_day_fixture.json`：更新为 schema v2 的测试夹具。
- `tests/test_weather_data_provider.gd`、`tests/test_weather_simulation_core.gd`、`tests/test_weather_simulation_analysis.gd`、`tests/test_weather_simulation_lab.gd`：窗口方向、重叠选择、边界、持续性、迁移、昼夜和 UI 报告测试。

## 自动化验证

Godot 4.7.2，均为 headless、离线测试；未进行真实 MET API 请求，也没有进行 Forward+ 肉眼画面验收。

| 测试 | 结果 |
|---|---:|
| `test_weather_data_provider.gd` | 69 项通过（损坏 JSON/模拟断网等分支会输出预期 warning） |
| `test_weather_simulation_core.gd` | 71 项通过 |
| `test_weather_simulation_analysis.gd` | 62 项通过 |
| `test_weather_simulation_lab.gd` | 69 项通过，布局尺寸 1280×720、1632×957、1920×1080 |
| `test_weather_simulation_lab_cache.gd` | 6 项通过；无 HTTP 请求 |
| `test_wind_field.gd` | 23 项通过 |
| `test_wind_field_lab.gd` | 30 项通过 |
| `test_wind_field_preset_ui.gd` | 8 项通过 |
| `test_weather_wind_integration.gd` | 49 项通过 |
| `test_day_night_cycle.gd` | 155 项通过 |

合计 542 项自动断言通过。主场景 `godot --headless --path . --quit-after 2` 以退出码 0 加载；昼夜测试和主场景退出各输出一次 Godot dummy renderer shader RID 清理告警，不影响退出码。由于使用 headless，没有据此声称 Forward+ 视觉验收通过。

## 未解决事项与 W2.2c 风险

1. Stockholm 本地日历日到 UTC 日界线仍需由明确使用时区数据库/时区转换能力的适配层计算。当前核心只验证和使用传入边界；默认缺省边界是向后兼容的 UTC 整日。
2. 6/12 小时窗口只能估计窗口内平均雨强和宽时段符号，不能恢复逐小时实测降雨变化；Lab 报告分辨率与覆盖率，不声称高精度。
3. 可能降水类别使用项目内部 0.55 概率门槛；该阈值未做气候校准。暴雨/雷暴的定量强度分级没有新增。
4. 运行时天气仍由现有手动天气与 F12 行为控制。W2.2b.1 未激活天气自动应用，也未修改暂停、倍率变化、存档和跨日重新锚定行为。W2.2c 接入时需保持权威时间线边界、已历历史和本地调试覆盖彼此隔离。

## 运行测试

```sh
godot --headless --path . --script res://tests/test_weather_data_provider.gd
godot --headless --path . --script res://tests/test_weather_simulation_core.gd
godot --headless --path . --script res://tests/test_weather_simulation_analysis.gd
godot --headless --path . --script res://tests/test_weather_simulation_lab.gd
```

其它 W1/W2.1 回归测试命令见各测试文件名，可用同样的 `godot --headless --path . --script res://tests/<name>.gd` 方式运行。
