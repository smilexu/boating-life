# W2.2a 天气数据接入与缓存报告

日期：2026-10-20  
项目：Godot 4.7.2 航海生活模拟器

## 结果摘要

W2.2a 已完成。真实天气数据采集、标准化、缓存和独立测试入口已经实现，但**没有接入正式游戏天气**。`WeatherStateController`、`WindField`、海浪、船舶和现有 F3/F12 面板均未由本阶段修改或调用。

真实 MET Norway 请求已在离线测试之外手动执行一次，并经 Godot `HTTPRequest` 得到 HTTP 200。离线自动化和真实 API 请求分别记录，模拟响应通过不代表真实服务通过。本次真实请求成功；真实 HTTP 304 仍未验证，因为服务器给出的缓存有效期尚未结束，不能提前再次请求。

## 架构与文件

```text
WeatherApiTestLab（手动测试场景）
  └─ WeatherDataProvider
      ├─ WeatherForecastCodec（纯数据转换与校验）
      ├─ MetNorwayHttpAdapter（异步 HTTPS）
      ├─ WeatherFileCacheStore（原子本地缓存）
      ├─ WeatherClockAdapter（UTC 墙钟）
      └─ WeatherRetryScheduler（非阻塞重试）

WeatherSimulationCoreContract → WeatherGodotAdapterContract
（W2.2b / Godot 天气适配契约；当前只验证数据，不产生或应用天气）
```

主要文件：

- `scripts/weather_data/weather_data_provider.gd`：分区读取、去重、过期判断、失败退避和回退策略。
- `scripts/weather_data/weather_forecast_codec.gd`：MET JSON 转为稳定的标准化天气文档；只依赖数据类型。
- `scripts/weather_data/weather_file_cache_store.gd`：按区域缓存，临时文件写完后原子替换；识别损坏和不支持的缓存版本。
- `scripts/weather_data/met_norway_http_adapter.gd`：使用线程化 `HTTPRequest`，设置超时、gzip 和有限重定向。
- `scripts/weather_data/weather_clock_adapter.gd`、`weather_retry_scheduler.gd`：隔离 UTC 读取和异步重试时间。
- `scripts/weather_data/weather_user_agent_settings.gd`：读取环境变量或本地配置。
- `docs/THIRD_PARTY.md`：记录 MET Norway 数据来源、归属和许可要求。
- `resources/weather_region.gd`、`resources/weather_region_oresund.tres`：可配置的天气区域定义；初始区域为 `oresund`，WGS84 坐标 `55.64, 12.78`。
- `scripts/weather_data/weather_simulation_core_contract.gd`、`weather_godot_adapter_contract.gd`：为 W2.2b 定义可序列化请求/响应和天气目标载荷，不含天气生成算法，也不调用游戏控制器。
- `scenes/WeatherApiTestLab.tscn`、`scripts/weather_api_test_lab.gd`：独立手动测试工具，不加入主场景或 F3/F12。
- `tests/fixtures/met_norway_complete_fixture.json`、`tests/test_weather_data_provider.gd`：合成的 MET 结构夹具与全离线自动测试。
- `config/weather_provider.local.example.json`：空白本地配置模板。

## 联系方式配置

代码没有内置私人邮箱，也不依赖 GitHub 地址。优先级为：

1. 环境变量 `MET_NORWAY_CONTACT`。
2. Godot 用户配置 `user://weather_data/provider_settings.json`。
3. 项目本机配置 `config/weather_provider.local.json`。

本机项目配置已按要求填入用户提供的联系信息，并已加入 `.gitignore`，不会进入提交。空白模板可复制后填写。测试场景也提供编辑、保存到用户配置和重载配置按钮；环境变量始终优先。发起请求前会检查联系信息，不合规则返回 `configuration_required`，不会联网。

## MET Norway 请求与真实服务验证

请求端点：

```text
https://api.met.no/weatherapi/locationforecast/2.0/complete?lat=55.6400&lon=12.7800
```

只按按钮手动请求，不在游戏启动、每帧、每艘船或周期轮询时访问。请求带产品名、用户配置的联系方式及 JSON Accept 头；收到响应后保留 `Last-Modified`、`Expires`、`Cache-Control`、`Date`、`Age` 和 ETag。新鲜缓存不可被调用方强制绕过；过期请求优先发送原样 `If-Modified-Since` 和 ETag 条件头。304 保留原响应体并更新缓存元数据。

**真实 API 独立手动验证：**

- 结果：HTTP 200，Godot `HTTPRequest` 成功完成；标准化与本地测试缓存写入成功。
- 预报发布时间：`2026-10-20T18:29:52Z`。
- 返回序列：86 个样本，首末有效时刻为 `2026-10-20T18:00:00Z` 至 `2026-10-30T18:00:00Z`。
- 首样本实际数据：10.7°C、相对湿度 92.7%、气压 1018.3 hPa、云量 1.0、风速 7.5 m/s、气象来向 96°、阵风 11.3 m/s；MET 返回 1/6/12 小时降水周期及 `lightrain` 天气符号（部分周期字段缺省）。
- 全 86 个样本都有温度、湿度、气压、风速、风向和云量；55 个样本带阵风；85 个样本带降水周期和天气符号。缺失项保持缺省，没有补造数值。
- 响应的 `Last-Modified` 为 `Tue, 20 Oct 2026 18:32:09 GMT`，`Expires` 为 `Tue, 20 Oct 2026 19:02:09 GMT`；这次响应没有提供 `Cache-Control`，因此按绝对 `Expires` 判断新鲜度。在报告生成时该有效期仍未结束，因此遵守缓存约束，没有再次请求，也未执行真实 304 测试。
- 真实请求缓存仅写入本次验证使用的 `.godot/weather_live_request_cache/`，没有复制为游戏正式缓存或接入天气状态。

官方使用要求与字段结构参考：

- [MET Norway 服务条款与客户端识别、缓存说明](https://api.met.no/doc/TermsOfService)
- [Locationforecast 请求与缓存 HOWTO](https://api.met.no/doc/locationforecast/HowTO)
- [Locationforecast 2.0 接口文档](https://api.met.no/weatherapi/locationforecast/2.0/documentation)
- [Forecast JSON 数据模型](https://api.met.no/doc/locationforecast/datamodel)
- [HTTP 状态码说明](https://docs.api.met.no/doc/StatusCodes)
- [MET Norway 数据许可证](https://api.met.no/doc/License)

归属信息随标准化数据保存为 `Data from MET Norway`，许可证记录 CC BY 4.0 与 NLOD 2.0。实际发布时仍需在游戏的第三方数据说明中保留适当归属和许可信息。

## 标准化数据约定

所有有效时刻统一为 UTC；风速为 m/s；风向为真北顺时针气象来向；云量和降水概率为 0–1；压力为 hPa；温度为 °C。降水以 `precipitation_periods` 列表保存，每条都明确带 `duration_hours`、开始/结束 UTC、可用的降水量及概率。阵风、概率、天气符号和其他缺失字段不会使用平均风速或猜测值填充。

简化示例（数值来自真实手动请求的首个样本，许可和来源元数据在完整文档中另存）：

```json
{
  "schema_version": 1,
  "provider_id": "met_norway_locationforecast_2_0_complete",
  "region_id": "oresund",
  "latitude": 55.64,
  "longitude": 12.78,
  "forecast_issued_at_utc": "2026-10-20T18:29:52Z",
  "retrieved_at_utc": "2026-10-20T18:32:09Z",
  "valid_from_utc": "2026-10-20T18:00:00Z",
  "valid_until_utc": "2026-10-30T18:00:00Z",
  "timeseries": [
    {
      "valid_time_utc": "2026-10-20T18:00:00Z",
      "air_temperature_c": 10.7,
      "relative_humidity_percent": 92.7,
      "air_pressure_hpa": 1018.3,
      "wind_speed_mps": 7.5,
      "wind_from_direction_deg": 96.0,
      "wind_gust_mps": 11.3,
      "cloud_fraction": 1.0,
      "precipitation_periods": [
        {
          "duration_hours": 1,
          "period_start_utc": "2026-10-20T18:00:00Z",
          "period_end_utc": "2026-10-20T19:00:00Z",
          "precipitation_amount_mm": 0.1,
          "precipitation_probability": 0.48
        }
      ],
      "weather_symbol": "lightrain"
    }
  ]
}
```

## 缓存、回退和稳定性

- 优先使用内存缓存，再读区域独立的磁盘 JSON；新鲜度与是否有缓存数据分别报告。
- provider 默认缓存位于 `user://weather_data/met_norway_locationforecast/{region_id}.json`；独立测试场景将真实响应与模拟响应分别放在项目 `.godot/` 下，避免改动游戏用户缓存并保留开发测试结果。
- `max-age` 优先于 `Expires`，并扣除 `Age`；`no-cache` 立即到期，`no-store` 只返回本次临时结果，不落盘。无服务器缓存头时使用可配置的一小时回退 TTL。
- 网络失败时，24 小时以内的旧缓存可回退并明确标记 stale；超过此限或没有缓存时返回 unavailable。
- 请求按区域去重。连接错误、无响应、超时、408/425/429 和部分 5xx 使用有限指数退避；识别秒数或 HTTP 日期格式的 `Retry-After`。连续失败后有 30 秒起步、封顶 15 分钟的冷却，并限流警告日志。
- JSON 根结构、必需时间字段、数值范围及缓存 schema 均会校验。异常缓存不会被当成实时数据。
- 网络请求非阻塞，HTTP 请求使用线程；天气数据层不依赖船只、HUD、场景或正式风场。

## 独立测试工具

在 Godot 编辑器中打开 `scenes/WeatherApiTestLab.tscn` 并按 **F6** 运行。或从项目根目录手动运行该场景。启动时只读缓存，不自动联网。

工具提供离线 Fixture 解析、模拟 200、模拟 304、断网、超时、损坏响应/缓存、模拟缓存清除、真实 API 缓存清除，以及单次真实 API 按钮。模拟请求使用单独缓存，绝不会污染真实 API 缓存。真实 API 按钮受响应缓存有效期限制；没有配置联系方式时会明确显示错误。

## 自动化验证

新增离线测试命令：

```text
godot --headless --path . --script res://tests/test_weather_data_provider.gd
```

结果：**58 项断言通过**。覆盖 MET 字段归一化、UTC 和闰日、JSON 往返、概率/降水时窗、缺少阵风、fresh/stale、磁盘缓存、过期刷新、304、断网回退、unavailable、损坏和不兼容缓存、损坏响应 JSON、请求去重、超时与 429 Retry-After、多区域隔离、no-store、联系信息注入，以及不依赖场景节点的未来数据契约。

此外，Godot 4.7.2 编辑器 headless 扫描和测试场景 headless 启动成功。W1/W2.1 回归测试也通过：WindField 23、WindFieldLab 30、风场预设 UI 8、天气/风场集成 49、昼夜周期 155 项断言。主场景 headless 启动至 30 帧，地形、风场和昼夜节点均正常加载。新增天气测试中的三条 warning（损坏 JSON 与两个网络失败）均由离线测试主动注入；昼夜测试和 headless 主场景退出时有 Dummy 渲染器资源泄漏提示，进程均以成功状态结束。

## 服务端迁移与 W2.2b 接口

单机版可在客户端实例化 `WeatherDataProvider`；多人版由权威服务器持有 provider 和区域缓存，客户端只接收标准化 forecast 或模拟输出 JSON。MET HTTP 适配器、缓存路径、系统墙钟和 Godot SceneTree 重试调度器属于可替换的边界；标准数据 codec、区域契约和未来天气过程输入/输出可以由服务端复用或同结构移植。客户端 F12 调试状态仍是本地表现，不进入此 provider。

建议 W2.2b 输入沿用 `WeatherSimulationCoreContract`：`schema_version`、`request_id`、`region_id`、UTC 起止时间、`simulation_seed` 和标准化 forecast 文档；输出按区域携带确定性的天气状态序列（有效时间窗、游戏视觉天气 ID、风况目标和来源）。核心负责纯数据计算，不访问 Node、Timer、网络或渲染；Godot adapter 再将一条序列状态交给 `WeatherStateController`。需要在 W2.2b 另定 12/24 游戏昼夜映射、持久化游标与服务器权威同步。本阶段未实现这些逻辑，也未接入海浪或船舶。

## 尚未完成/验证边界

- 真实服务已完成一次 200 响应验证；真实 304、限流 429、断网时服务器实际行为仍需在缓存合规的时机手动验证。相应逻辑已由完全离线模拟测试覆盖。
- 当前只有一个可配置的 Øresund 参考点；不是北欧气候模型，不代表海域内的完整空间天气。
- 预报标准化保留离散有效时刻；没有做插值、游戏天气日生成、存档同步或多人传输。
- API Lab 场景通过 headless 加载检查，尚未做不同分辨率的人工 UI 视觉验收。
