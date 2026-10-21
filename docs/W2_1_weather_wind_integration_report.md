# W2.1 天气状态与 WindField 整合报告

日期：2026-10-20  
Godot：4.7.2  
范围：天气状态统一管理、正式风况接入、阵风时钟分离、F12 临时风场覆盖。

## 完成内容

新增 `WeatherStateController`，作为正式天气状态与风况目标的唯一管理者。它把视觉天气预设交给现有 `WeatherController`，把风况通过受控接口传给 `WindField`。没有重写云层、天空或天气视觉渲染。

快捷键 `1/2/3` 和 HUD 天气按钮都改为调用 `WeatherStateController`。`WeatherController` 不再自行监听这组按键，也不再拥有正式天气状态；其视觉预设接口仍由统一控制器调用。没有建立循环依赖。

## 风况配置

新增 `WeatherWindProfile` Resource 与 Clear、PartlyCloudy、Overcast 三个配置资源。当前数值是临时游戏调试参数，**不是北欧实测气候数据**。

| 视觉预设 | 平均风速 | 气象来向 | 阵风强度 | 阵风时间尺度 | 阵风空间尺度 | 风向扰动 |
|---|---:|---:|---:|---:|---:|---:|
| Clear | 4.5 m/s | 240° | 1.2 m/s | 24 s | 500 m | 6° |
| PartlyCloudy | 7 m/s | 260° | 2.5 m/s | 20 s | 400 m | 10° |
| Overcast | 9.5 m/s | 285° | 4 m/s | 18 s | 350 m | 12° |

风向字段采用气象来向，角度从真北顺时针。`WindField.get_wind_at(world_position)` 继续返回世界空间的空气去向速度矢量，坐标仍为 X=东、Y=上、Z=南。

天气风况在配置之间平滑插值，风向使用最短角度路径；中途再次切换时从当前插值风况重新开始。默认过渡时间为 300 秒游戏模拟时间，与视觉天气的 5 秒现实时间转场分开配置。调试短转场模式使用可配置的现实运行时间。

## 阵风时钟

WindField 的 FastNoiseLite 阵风采样算法与空间采样行为未改。变化的是时间来源：正式风场现在由独立运行时钟驱动。

- 昼夜倍率为 1、24 或 60 时，阵风都按物理运行秒推进。
- `WorldTimeManager.pause_time()` 只暂停昼夜时钟，不冻结阵风。
- 真正暂停 SceneTree 时，WindField 作为 `PROCESS_MODE_PAUSABLE` 节点停止，阵风也随之暂停。
- WindFieldLab 保留本地测试时间覆盖，不受正式天气控制。

## F12 临时覆盖

正式天气风况与调试覆盖分开保存。F12 改动只写入 WindField 的临时覆盖，不会改写 WeatherStateController 的天气目标或天气资源。正式天气可以在覆盖期间继续变化。

关闭 F12 面板时：

1. 临时参数覆盖平滑解除，并回到当时最新的正式风况；默认恢复时间为 1.5 秒。
2. 本地测试时钟单独关闭，WindField 恢复使用运行时阵风时钟。
3. 主游戏模式的随机种子控件不可编辑，避免恢复时突然重建阵风噪声场。

面板显示当前处于正式天气、临时覆盖或覆盖恢复阶段。WindFieldLab 的本地测试参数仍独立运行。

## 场景与接口

`main.tscn` 显式放置并连接 `WindField`、`WeatherStateController`、`WeatherController`、`WorldTimeManager` 和 `WindFieldDebugPanel`，没有新增 Autoload。

面向 W2.2 的入口为：

```gdscript
apply_climate_weather_target(
    weather_id,
    visual_preset_index,
    wind_profile,
    region_id,
    date
)
```

ClimateModel 可提供动态风况 Resource 和气候地区/日期；WeatherStateController 负责应用过渡，不要求气候系统直接写 WindField 或视觉节点。之后仍需定义气候样本映射到现有视觉天气预设的规则。

`get_persistence_snapshot()` 提供未来存档所需的描述字段：schema 版本、当前/目标天气 ID、当前/目标风况、过渡进度与时长、过渡时钟类型、气候地区与日期、风场种子、阵风运行时钟。**W2.1 尚未实现天气存档、加载或过渡恢复。**

## 文件变更

新增：

- `scripts/weather_state_controller.gd`
- `resources/weather_wind_profile.gd`
- `resources/weather_wind_clear.tres`
- `resources/weather_wind_partly_cloudy.tres`
- `resources/weather_wind_overcast.tres`
- `tests/test_weather_wind_integration.gd`

更新：

- `scenes/main.tscn`：添加并连接天气/风场节点。
- `scripts/wind_field.gd`：接入正式天气设置接口、独立运行时阵风时钟和调试覆盖恢复。
- `scripts/weather_controller.gd`：聚焦视觉天气应用，保留现有视觉转场。
- `scripts/wind_field_debug_panel.gd`：F12 临时覆盖、独立测试时钟和模式提示。
- `scripts/boat_hud.gd`：天气按钮改由 WeatherStateController 处理，并保留快捷键提示。
- `scripts/shallow_water_test_controller.gd`：天气预设重置改走统一控制器。
- `tests/test_day_night_cycle.gd`：验证主场景状态控制器，并更新天气入口和过时的自动巡航测试调用。

本轮没有修改 `boat_controller.gd`、`wave_sampler.gd`、浮力或海洋 Shader。天气视觉预设原有的波浪视觉行为保持原样。

## 自动化验证

Mac 本地 Godot 4.7.2 检查结果：

| 检查 | 结果 |
|---|---:|
| WindField 核心测试 | 23 项通过 |
| WindFieldLab 测试 | 30 项通过 |
| 风向预设 UI 测试 | 8 项通过 |
| WorldTimeManager 测试 | 70 项通过 |
| 昼夜/天气视觉测试 | 155 项通过 |
| W2.1 天气与风场整合测试 | 49 项通过 |
| Godot 编辑器解析/导入 | 退出码 0 |
| main 场景无头加载 | 退出码 0 |
| `git diff --check` | 通过 |

上述专项测试共报告 335 项检查通过。整合测试覆盖三种预设、快捷键转发、风况传递、跨 0° 插值、连续重定目标、昼夜倍率/暂停与阵风时钟隔离、SceneTree 暂停、F12 覆盖隔离和恢复、WindFieldLab 独立运行及存档描述字段。

无头解析与场景加载日志包含 `No rendering device on load`；退出时 Godot 也报告 DummyShader/ObjectDB 清理警告。该运行方式没有 Forward+ 画面，因此**没有完成可视化验收**，也没有据此报告帧率或渲染效果。

## 未完成与后续边界

- 没有接入北欧气候统计、真实天气数据、降雨或风暴。
- 没有实现天气状态持久化和读档恢复。
- 没有把风场接入海浪物理、浮力、船舶驾驶或风机逻辑。
- 需要后续在 Forward+ 中手动确认 F12 布局与天气转场观感。

工作区开始时已有未提交的 W1 文件及其他场景改动，本轮保留了这些工作，没有清理或回退。
