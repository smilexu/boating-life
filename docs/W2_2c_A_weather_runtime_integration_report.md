# W2.2c-A：真实天气运行时接入报告

日期：2026-10-20  
Godot：4.7.2.stable.official.ed1daf0bf

## 结果摘要

已把 Provider、WeatherSimulationCore、WorldTimeManager、WeatherStateController 和 WindField 接成一条运行时流程。主场景启动时先读 Provider 缓存；有可用缓存就生成 Øresund 天气时间线并进入 AUTO。过期但仍可接受的缓存继续使用，同时按 Provider 的缓存规则后台更新。没有可用预报时不造实时天气，游戏保留原有安全天气并显示不可用或配置错误。

本轮没有改动 WindField 阵风算法、WeatherSimulationCore 天气算法、WorldTimeManager、海浪或船舶物理。没有完成 Forward+ 肉眼验收，也没有把本轮 headless 启动当作视觉验证。真实 MET Norway HTTP 响应也没有在本轮单独验证；Provider 的离线路径由模拟 Provider 测试覆盖。

## 数据流与职责

```text
WeatherRuntimeAuthority
  ├── WeatherDataProvider（RefCounted；Provider 内部创建 HTTP / 缓存 / 时钟适配器）
  ├── WeatherSimulationCore（纯数据时间线生成及采样）
  └── WeatherRuntimeGodotAdapter
        └── WeatherStateController
              ├── WeatherController（仅在视觉预设变化时开始原有转场）
              └── WindField（正式目标；F12 仍是临时覆盖）
```

`WeatherRuntimeAuthority` 是单机本地权威实例；不操作 Shader、船舶、海浪或 HUD。Provider 继续负责 User-Agent、HTTP 条件请求、缓存、重试、退避与 stale 回退。运行时每 60 秒检查一次 Provider 状态，但只有 Provider 判定缓存到期时才请求；每次只针对 `oresund` 区域请求一次，不按船只或帧发请求。

核心天气状态每 2 秒现实运行时间采样一次。Core 已对风、云等连续字段插值，`WeatherStateController` 用 2 秒现实时间的一阶跟踪器追踪新风况目标，不再重复启动 W2.1 的 300 秒转场。视觉预设只有 Clear / PartlyCloudy / Overcast 真正改变时才调用 `WeatherController`，继续使用它原有的 5 秒视觉过渡。MET 风向仍是从向（真北顺时针），风速为 m/s；阵风目标复用 Core 的 `max(0, forecast_gust - mean_wind) * excess_factor` 映射，不把预报峰值直接作为噪声幅度。

## Stockholm 日期边界与游戏日轮

新增 `WeatherStockholmCalendarAdapter`。它从 WorldTimeManager 的权威 UTC 时间调用现有 Stockholm 日期及 CET/CEST 偏移规则，计算真实当地午夜的 UTC 时间戳。转换以当地午夜的实际 UTC 偏移做固定点求解，避免误用 WorldTimeManager 为 24 小时加速游戏时钟设计的“DST 转换日整天使用新偏移”规则。

时间线边界默认从当前 `Europe/Stockholm` 日期起覆盖连续 7 个当地日历日。核心接收显式 UTC 边界、当地日期标签和 `Europe/Stockholm` 边界依据；23/25 小时日期在时间线上按实际 UTC 时长映射，但仍分别生成固定 12 或 24 个游戏昼夜。默认目标为每天 24 个游戏昼夜，必须与 WorldTimeManager 的 `time_scale=24` 匹配。目标日轮数与当前倍率是两个独立字段。

`WorldTimeManager.pause_time()` 不改变日轮游标，因此正式天气游标冻结；WindField 的独立阵风时钟仍按已有规则运行。真正的 `SceneTree` 暂停会暂停 Authority、WorldTimeManager、WeatherStateController 和 WindField 的可暂停处理。

运行中若倍率改变，Authority 锁存时间映射冲突，停止发布新天气，不会偷偷重映射或重置当前天气。恢复倍率本身不会清除冲突。检查 Inspector 配置后可显式调用：

```gdscript
get_node("/root/Main/WeatherRuntimeAuthority").reanchor_authoritative_timeline(12)
```

参数只接受 12 或 24，并且必须和当前 WorldTimeManager 倍率一致。此操作会以当前权威游标建立新时间线；WindField 风况经短时跟踪器平滑恢复。它属于明确的时间线重锚定，不是存档恢复，也不提供已经历历史的持久化。

### DST 测试结果

| Stockholm 日期 | UTC 边界时长 | 结果 |
|---|---:|---|
| 2026-01-15（冬季） | 24 小时 | 通过 |
| 2026-07-15（夏季） | 24 小时 | 通过 |
| 2026-03-29（春季切换） | 23 小时 | 通过 |
| 2026-10-25（秋季切换） | 25 小时 | 通过 |
| 2026-10-19 22:30 UTC | Stockholm 日期已为 2026-10-20 | 通过 |

日期规则沿用项目 WorldTimeManager 当前编码的 EU DST 规则；若当地法规未来变化，需要更新该既有规则和对应测试。

## AUTO、MANUAL、F12

- **AUTO**：Authority 是正式天气目标唯一来源。主场景启动后即进入 AUTO；风况来自时间线当前游标。
- **MANUAL**：按 `1 / 2 / 3` 选择 Clear、PartlyCloudy、Overcast 会切换到手动模式。Authority 继续维护和更新时间线，但不会覆盖手动天气。
- **返回 AUTO**：按 `0`。Authority 从当前权威日轮游标重新采样，不回到进入 MANUAL 时的旧天气。
- **F12**：继续只覆盖 WindField 的临时有效风况。Authority / WeatherStateController 仍可更新正式目标；关闭 F12 后 WindField 按已有逻辑恢复到最新正式目标。

F3 天气按钮继续走 WeatherStateController，因此同样切换为 MANUAL；没有改变 F3/F12 的已有面板行为。新增的运行时诊断是独立、debug-build 才显示的小面板，展示 AUTO/MANUAL、区域、缓存来源、时间线质量、日期、日轮、天气、风况、刷新状态及映射冲突，不占用 F3 或 F12 快捷键。

## Provider、缓存与数据质量

Authority 直接使用既有 `WeatherDataProvider`，不重新实现 HTTP、缓存或重试逻辑：

1. 内存 / 磁盘有效缓存优先用于启动。
2. 过期缓存只有在 Provider 标记 `stale_acceptable` 时才用作天气来源，同时按服务端缓存规则刷新。
3. 无缓存时通过 Provider 发起一次异步请求；请求失败由 Provider stale 回退或返回 unavailable。
4. 缺少 MET Norway 联系信息时显示配置错误，不发请求，并阻止每分钟反复请求；配置补齐后可调用 `reload_provider_contact_configuration()`。
5. HTTP 缓存新鲜度与 Core 的数据完整性分开显示：`fresh_cache / stale_cache / live_network_response / unavailable` 对应来源状态；`fresh / partial / stale / stale_partial / unavailable` 对应时间线覆盖质量。

配置继续由 `MET_NORWAY_CONTACT` 环境变量、`user://weather_data/provider_settings.json` 或被忽略的 `config/weather_provider.local.json` 提供。Authority 快照不包含联系人、HTTP 私密配置或本地缓存路径。

预报变更时，Authority 复用原时间锚点和当地日期边界，调用 `WeatherSimulationCore.update_forecast()`；已经历区段原样保留，未来天气在 1 个游戏日轮内平滑混合。时间线到达 7 日范围末端时不会自动改锚点；会报告 `timeline_expired_reanchor_required`，等待显式重锚定。该策略避免悄悄改写历史，但需要后续决定长期运行的重锚定流程。

## 权威快照

`get_authoritative_weather_snapshot()` 和 `serialize_authoritative_snapshot()` 提供只读可序列化快照，包含：

- `schema_version`、`region_id`、时间线版本和随机种子。
- Forecast Provider / 发布时间 / 有效时间范围与来源质量。
- Authority 时间锚点与当前日轮游标。
- 当前 Core 天气样本。
- 缓存来源状态、预报覆盖质量、时间映射状态。
- 完整可序列化天气时间线，供未来客户端恢复呈现，不要求客户端调用 MET 或重跑生成器。

本阶段没有实现文件存档、多人通信、客户端同步或网络权限校验。

## 文件变更

新增：

- `scripts/weather_runtime/weather_runtime_authority.gd`
- `scripts/weather_runtime/weather_runtime_godot_adapter.gd`
- `scripts/weather_runtime/weather_stockholm_calendar_adapter.gd`
- `scripts/weather_runtime/weather_runtime_diagnostics.gd`
- `tests/test_weather_runtime_integration.gd`
- `tests/test_weather_stockholm_calendar_adapter.gd`
- `docs/W2_2c_A_weather_runtime_integration_report.md`

修改：

- `scenes/main.tscn`：添加 Oresund 天气区域资源、Godot Adapter、Authority 和开发者诊断节点。
- `scripts/weather_state_controller.gd`：加入 AUTO/MANUAL 所有权、手动 / 自动快捷键、运行时天气目标跟踪。
- `scripts/boat_hud.gd`：标注 `0 自动天气 / 1-3 手动天气`；已有 F3 天气按钮继续委托 WeatherStateController。

## 自动化验证

Godot 4.7.2，全部离线运行，无需真实 MET 请求：

| 测试 | 断言数 | 结果 |
|---|---:|---|
| `test_wind_field.gd` | 23 | 通过 |
| `test_wind_field_lab.gd` | 30 | 通过 |
| `test_wind_field_preset_ui.gd` | 8 | 通过 |
| `test_weather_wind_integration.gd` | 49 | 通过 |
| `test_weather_data_provider.gd` | 69 | 通过；故障分支的预期 warning 来自模拟响应 |
| `test_weather_simulation_core.gd` | 71 | 通过 |
| `test_weather_simulation_analysis.gd` | 62 | 通过 |
| `test_weather_simulation_lab.gd` | 69 | 通过（1280×720、1632×957、1920×1080） |
| `test_weather_simulation_lab_cache.gd` | 6 | 通过；不发 HTTP |
| `test_weather_stockholm_calendar_adapter.gd` | 14 | 通过 |
| `test_weather_runtime_integration.gd` | 42 | 通过；注入离线模拟 Provider |
| **总计** | **443** | **通过** |

Runtime 集成断言覆盖 fresh/stale/unavailable、缺少联系信息、异步新预报、AUTO/MANUAL 与 `0` 恢复、F12 隔离、日轮暂停游标、12/24 模式、倍率冲突及显式重锚、快照往返和敏感本地配置排除。

另外执行了 `godot --headless --path . --editor --quit` 和 `godot --headless --path . --quit-after 5`：两者均以 exit code 0 结束，主场景离线启动加载到区域场景。Headless Editor 退出时报告一个 ObjectDB 实例泄漏；无渲染设备的主场景退出报告一个 dummy renderer Shader RID 泄漏。这不是图形性能或视觉验收结论。

## 尚未完成与人工验收

1. **Forward+ 肉眼验收未完成**：本轮没有检查 AUTO 随游戏日轮变化、天空切换、手动返回 AUTO、F12 覆盖恢复或闪烁。Headless 测试不能替代这些验收。
2. **真实 MET Norway 在线请求未在本轮确认**：离线测试使用 Fixture / 模拟 Provider；已有 Provider 的网络行为被复用，但不能据此声称本次运行收到了 HTTP 200。
3. **主场景的 `quit-after 5` 只验证加载和初始化**：没有等待一个完整在线响应周期，也没有证实本地缓存当时属于 fresh / stale。
4. **长期运行范围为 7 个当地日历日**：过期后需要外部显式调用重锚；自动滚动窗口与存档属于后续工作。
5. **天空仍只有三个既有视觉预设**：雨雪、雷暴效果没有新增。
6. **W2.2c-B 未实施**：天气时间线 / AUTO-MANUAL 模式没有跨存档持久化。

### 建议肉眼验收步骤

1. 在 Forward+ 启动主场景，检查右上诊断中的来源、数据质量及时间映射状态；无缓存时确认游戏仍能进入，面板显示不可用或联系配置错误。
2. 使用有效缓存 / 在线数据运行，等待天气游标跨越预报关键时段；验证视觉预设只在变化时转场，风速与风向连续更新。
3. 按 `1 / 2 / 3` 切到 MANUAL，再按 `0`；确认返回当前天气时间线游标，而不是之前的旧天气。
4. 打开 F12 改变临时风，确认 AUTO 正式目标继续更新；关掉 F12 后确认回到最新正式风况。
5. 通过现有时间倍率控件制造 `time_scale` / `cycles_per_real_day` 不匹配，确认状态报冲突且天气停止重映射；将倍率与 12/24 配置对齐后显式调用 `reanchor_authoritative_timeline(12 或 24)`。

