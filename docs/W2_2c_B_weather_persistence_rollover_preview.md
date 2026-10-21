# W2.2c-B：天气持久化、长期运行与时间线预览

## 结果概览

已完成天气运行时存档恢复、自动时间线续接、离线安全回退和只读开发预览。没有修改 `WeatherSimulationCore` 的天气算法、`WorldTimeManager` 计时规则、WindField 阵风算法、天气视觉实现或船舶/海浪逻辑。

十日长测使用注入的虚拟 UTC 时钟、模拟 WorldTimeManager 游标、离线 Provider 和独立临时存档。没有通过 Timer、真实等待、逐帧推进或时间倍率推进日期。长测覆盖十个活动日轮边界，另有暂停跨午夜与离线恢复测试。

## 文件

- 新增 `scripts/weather_runtime/weather_runtime_persistence.gd`：版本化存档、校验和原子写入。
- 修改 `scripts/weather_runtime/weather_runtime_authority.gd`：启动恢复、周期保存、时间映射保护、时间线自动续接、历史保留、断网回退和预览查询。
- 新增 `scripts/weather_runtime/weather_runtime_preview_panel.gd`：只读预览面板。
- 修改 `scenes/main.tscn`：接入预览面板节点。
- 新增 `tests/test_weather_runtime_persistence_rollover.gd`：持久化、预览隔离、虚拟时钟长测。
- 修改 `tests/test_weather_runtime_integration.gd`：FakeClock 提供虚拟 UTC 接口；避免测试误用宿主机时钟。

## 持久化和恢复

默认存档为 `user://weather_data/weather_runtime_state.json`，格式 `weather_runtime_state`，`schema_version = 1`。保存内容包括区域、AUTO/MANUAL 模式和手动预设、随机种子、活动时间线、锚点、当前游标、Stockholm 日期边界、预报及来源元数据、当前/最后有效天气样本、已归档历史和恢复/续接状态。F12 临时风场覆盖、测试时钟、联系邮箱、User-Agent 和本地绝对路径不进入存档。

`WeatherRuntimePersistence.save_state()` 先写入同目录临时文件并 flush，再 rename。平台不能直接覆盖时会将上一份文件暂存为备份，替换失败则恢复上一份有效文件。存档会验证 schema、区域、标准化预报、活动时间线、时间线版本/种子/日期边界、游标和归档历史片段。活动时间线按 Core 契约验证；历史是裁剪后的部分片段，因此使用独立的有序关键帧和区间校验。

保存时机：状态变化后延迟保存、运行中约每 30 秒自动保存、退出时保存。Provider 自身缓存独立管理，不与运行时存档混用。

恢复顺序：`WorldTimeManager` Autoload 先恢复自己的状态；主场景里的 Authority 取得当前权威快照后，读取并验证天气存档，再恢复 AUTO/MANUAL、种子、时间线与游标，随后读取 Provider 缓存并执行一次运行时调度。找不到或读坏天气存档不会阻止航行；不兼容的游标、倍率或日期映射会进入待重锚状态，而不是静默套用旧游标。

WorldTimeManager 在退出期间没有推进日轮时，天气系统不补算离线游戏日轮。现实日期仍取当前 UTC 并转换为 `Europe/Stockholm`；若日期已变，则以当前冻结的日轮游标重新建立未来锚点，同时以最后有效天气样本作为连接状态。测试覆盖两天离线时间跳转而游戏游标保持不变。

## 自动续接、历史和数据回退

时间线剩余覆盖小于等于 `timeline_rollover_lead_cycles`（默认 1.5 个游戏日轮）、Stockholm 日期需要重建，或恢复状态要求重锚时，Authority 会准备新时间线。它先采样当前游标并检查 Provider 缓存；只有 Provider 标记刷新到期时才请求更新。相同预报指纹不会重复生成。

新预报在活动时间线仍有效时交给 `WeatherSimulationCore.update_forecast()`。Core 保留当前游标之前的关键帧，并平滑未来区间；自动重建则把最后有效样本作为新时间线边界，在默认 1 个游戏日轮的过渡窗口内衔接。历史按片段保存，默认保留最近 14×24 小时 UTC 范围；过旧片段会裁剪。历史不要求永久保留完整原始时间线。

当预报覆盖结束或 Provider 不可用时，不为未来合成真实天气。系统保持最后有效天气，并将数据质量标记为 `held_last_known`；恢复新鲜数据后从当前状态平滑接回。缓存新鲜度、数据质量和时间映射冲突分别记录。

倍率映射冲突由 `WorldTimeManager.state_changed` 立即检查，天气采样调度也会再次校验；不在渲染帧中轮询世界时钟。倍率不匹配会锁定映射冲突；即使倍率恢复，也不会自动清除冲突。必须显式调用重锚接口，重锚会记录原因、版本变化并归档旧区间。暂停天气时游标冻结；现实午夜不会强行推进，恢复后才按现时日期重新规划。Stockholm DST 边界由现有日历适配器提供真实 UTC 边界：本次十日运行经过 2026-10-25 的 25 小时日期；23 小时春季日期由既有 Core 和日历适配器回归测试覆盖。

## 预览工具

主场景 debug build 下按 **Ctrl+Shift+F12** 打开/关闭“天气时间线预览”。F11 已用于浅海床测试，普通 F12 保留风场覆盖面板，因此预览使用组合键。

面板显示当前正式天气、所选时间线天气、来源/质量、映射状态、预报发布时间、时间线版本、剩余覆盖和最近续接状态。默认选中当前权威游标，可用日轮偏移选择时间，并可一键回到当前游标。

面板通过 Authority 的只读采样接口读取活动时间线，不调用 Provider，不发 HTTP 请求，不写存档，不修改 WorldTimeManager、WeatherStateController 或 WindField，也不改变种子或 AUTO/MANUAL 模式。

## 运行时/多人边界

天气权威仍是 `WeatherRuntimeAuthority`：Provider 提供标准化预报，SimulationCore 生成/采样纯数据时间线，Persistence 保存权威状态，Godot Adapter 只负责把样本提交给 `WeatherStateController`。快照保持可序列化，未包含联系人、HTTP 私有配置或本地路径。未来多人版可将 Provider、Authority 和 Persistence 移至服务器；客户端仅消费权威快照并呈现，不在本地请求 MET Norway 或自行生成天气。本阶段没有实现网络同步。

## 验证

### 十日虚拟时间测试

命令：

```sh
godot --headless --path . --script res://tests/test_weather_runtime_persistence_rollover.gd
```

当前结果：93 项专项断言通过。最后一次计时中，十日 Authority 场景（含 fixture 时间线生成、节点配置/清理和十个虚拟日轮边界）用时 **7862 ms**，低于 10 秒目标。测试包含：

- 第 3 日新预报更新，并逐帧比较已经历历史；相同预报再次送达不会重生成。
- 第 4 日模拟断网，沿用原时间线并标为 stale/unavailable。
- 第 5 日恢复新预报、验证同一游标天气连续、存档和重启后恢复 AUTO/种子/时间线。
- 自动跨过七日时间线覆盖边界并归档历史。
- 十个活动日轮边界后，游标连续且样本仍在 fixture 的真实有效覆盖范围内。
- 单独测试两天离线恢复：现实日期前进、游戏日轮游标冻结、天气锚点重建、已保存历史保持原样。
- 测试暂停跨现实午夜、MANUAL 恢复、损坏/不兼容存档、失败写入保留原文件、预览只读和不发请求。
- 预览只读界面可由 Ctrl+Shift+F12 测试事件打开/关闭。
- 秋季 25 小时 Stockholm 日期出现在活动时间线中；既有 Core 回归测试覆盖春季 23 小时日期。

这一计时统计的是十日场景函数本身。独立 Godot 命令的墙钟时间是 **14.12 秒**，比十日场景计时多约 6.26 秒。差额包含引擎/项目启动、前置的存档/预览/暂停/离线恢复测试及进程退出；本次没有单独拆分这些部分。若 10 秒目标指整条冷启动命令，而非虚拟十日状态机本身，当前命令尚未达到该目标，需要进一步 profiling。

### 回归测试

最后一轮离线回归总计 537 项通过：

| 测试 | 结果 |
|---|---:|
| `test_wind_field.gd` | 23 通过 |
| `test_wind_field_lab.gd` | 30 通过 |
| `test_wind_field_preset_ui.gd` | 8 通过 |
| `test_weather_wind_integration.gd` | 50 通过 |
| `test_weather_data_provider.gd` | 69 通过（模拟错误响应的预期 warning） |
| `test_weather_simulation_core.gd` | 71 通过 |
| `test_weather_simulation_analysis.gd` | 62 通过 |
| `test_weather_simulation_lab.gd` | 69 通过 |
| `test_weather_simulation_lab_cache.gd` | 6 通过，无 HTTP |
| `test_weather_stockholm_calendar_adapter.gd` | 14 通过 |
| `test_weather_runtime_integration.gd` | 42 通过，离线 FakeProvider |
| `test_weather_runtime_persistence_rollover.gd` | 93 通过 |

`godot --headless --path . --editor --quit` 完成资源/脚本扫描，没有 GDScript 解析错误；退出时仍报告一个 `ObjectDB instance was leaked` 警告，来源未定位。`git diff --check` 通过。

此前执行过 `godot --headless --path . --quit-after 2` 主场景烟测，场景节点和资源成功加载；因为是 headless，没有 Forward+ 画面，且关机时报告一个 dummy renderer shader RID 泄漏。这不算视觉验收。

## 未完成与注意事项

- 没有进行 Forward+ 人工画面验收；请在主场景运行后用 Ctrl+Shift+F12 检查预览面板布局和内容。
- 十日模拟依赖离线 Fixture/模拟 Provider；没有连接或验证实时 MET Norway 服务，也没有证明真实连续运行十天的稳定性。
- 本地存档 schema 当前为 v1；未来新增字段需升级并提供迁移或显式拒绝策略。
- 目前没有完整天气历史永久数据库，也没有服务器同步实现。
- 时间倍率冲突仍需开发者显式重锚，这是为避免无提示天气跳变而保留的安全行为。
- **本机存档测试副作用说明：**虚拟自动化测试使用 `user://weather_runtime_persistence_rollover_tests/` 独立目录，并在结束时清理。但额外的主场景 headless 烟测使用了普通 Godot `user://`。主场景退出会调用现有 `WorldTimeManager` 保存以及本任务的天气运行时保存，因此那次烟测可能更新了本机 `user://world_time_state.json` 与 `user://weather_data/weather_runtime_state.json`。运行前没有复制备份；我没有尝试删除或伪造恢复这两份本地文件。未来需用隔离用户数据目录/临时项目副本运行主场景烟测。
