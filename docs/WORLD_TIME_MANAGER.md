# WorldTimeManager

本阶段只提供可复用的时间状态与逻辑，不连接太阳、天空、云层、海水 Shader 或 UI。

## 结构

- `scripts/world_time_state.gd`：纯数据 `WorldTimeState`，可序列化为字典，不引用场景节点或渲染对象。
- `scripts/local_authority.gd`：当前单机使用的 `LocalAuthority`。它提供可注入的单调时钟与 UTC 墙上时钟。
- `scripts/world_time_manager.gd`：时间服务，已注册为 `WorldTimeManager` Autoload。Headless 运行时可直接使用。
- `scripts/world_time_client_view.gd`：客户端只读预测视图；接受权威快照、补偿网络延迟并以未缩放真实时间推进，不提供权威修改接口。
- `scripts/world_time_control_port.gd` 和 `scripts/local_world_time_control.gd`：F3 UI 的可替换控制端口及本地开发适配器。
- `tests/test_world_time_manager.gd`：使用注入时钟的确定性自动化测试。
- `tests/test_world_time_client_sync.gd`：两个独立客户端实例的延迟、纠偏、控制修订和旧包拒绝模拟。

## 状态字段

`WorldTimeState` 包含：

- `calendar_date`：当前世界显示日期，Stockholm 本地年月日；若启用管理员覆盖则为固定覆盖日期。
- `real_calendar_date`：由当前 UTC 权威墙钟换算得到的真实 Stockholm 日期。
- `day_cycle_index`：服务启动后自然完成的全局日轮数。初始化的当前日轮为 0。
- `cycle_seconds`：当前日轮相位，范围 `[0, 86400)`。
- `time_scale`：日轮倍率，默认 `24.0`。
- `paused`：只暂停日轮，不暂停现实日期更新。
- `authoritative_timestamp_utc`：最近一次权威 UTC 时间戳。
- `monotonic_anchor_usec`：进程本地单调时钟锚点；仅用于本地诊断，恢复时总会重设。
- `state_revision`：管理员变更或自然跨轮后的修订号。
- `authority_control_revision`：仅管理员/权威控制变更时递增；自然跨轮不递增，用于区分延迟到达的跳时/倍率/暂停/日期修改。
- `revision_reason`：最近一次修订原因，便于诊断与同步决策。
- `calendar_override_enabled` / `calendar_override_date`：显式标记的静态管理员日期覆盖。
- `local_day_cycle_ordinal` / `local_day_cycle_date`：真实 Stockholm 日期内已记录的日轮起始次数及其日期。它不从倍率推算；若今天尚未发生日轮起始事件，序号为 0。
- `cycle_starts_by_local_date`：保留最近 45 个真实本地日期的日轮起始计数，并包含最近一次起始事件信息。

物理系统继续使用 Godot 原生未缩放的 `_physics_process(delta)`。管理器不设置 `Engine.time_scale`；`get_last_real_delta_seconds()` 返回单调时钟测得的真实间隔。

## 主要接口

通过 Autoload `WorldTimeManager` 调用：

- `get_time_state()` / `get_authoritative_state()`：同步后获取状态对象或权威快照。
- `set_day_cycle_time(hour, minute, second)`、`set_cycle_seconds(seconds)`：管理员手动设置日轮相位。手动跳时不会改变全局日轮编号，也不记为自然日轮起始。
- `set_time_scale(scale)`：接受 `(0, 1000]` 的正倍率；常用 1、12、24、60。
- `pause_time()` / `resume_time()`：日轮暂停/恢复，真实日历仍更新。
- `set_calendar_date(year, month, day)` / `clear_calendar_override()`：设置/清除固定日期覆盖。
- `create_snapshot()` / `restore_snapshot(snapshot, advance_from_authoritative_timestamp=false)`：创建及恢复快照。快照包含 `authority_session_id`、`authority_snapshot_sequence` 和 `authority_sync_anchor`；进程单调时钟不跨进程传输。默认精确恢复；可选按 UTC 快照时间估算补进日轮，但生产多人同步应由服务器时钟/传输延迟估算替代本地墙钟补时。
- `save_state(path)` / `load_state(path)`：保存和恢复 JSON 状态。
- `get_real_utc_timestamp()` / `get_real_calendar_date()`：始终提供真实 UTC/Stockholm 日期，天气服务应使用它们而不是管理员覆盖日期。

`set_clock_sources(monotonic_usec_callable, utc_unix_callable)` 可在 `initialize_runtime()` 前注入时钟，主要用于自动化测试和未来服务器适配。

## Stockholm 时区规则

实现使用统一 UTC 时间戳，再转换为 `Europe/Stockholm` 民用日期：冬季 CET 为 UTC+1，夏季 CEST 为 UTC+2。当前规则按欧盟现行切换点计算：3 月最后一个星期日 01:00 UTC 开始夏令时，10 月最后一个星期日 01:00 UTC 结束夏令时。UTC 时间戳不因夏令时重复/跳过的本地小时而歧义；月末、年末均由 UTC 时间戳转换处理。

实现针对当前及现代欧洲规则的运行期日期（包括当前年份和后续年份）。它不是完整历史 IANA tzdb，若未来服务器必须支持历史日期或欧洲修改法定切换规则，应迁移到带版本的 IANA 时区数据库，而不是依赖客户端操作系统时区。

日轮由 `Time.get_ticks_usec()` 单调时钟推进，操作系统墙钟回拨不会倒退日轮。若墙钟在单次更新中发生明显校正，跨轮事件仍按单调时钟发生顺序记录，并归入校正后的 UTC 日期附近；真实显示日期始终以 UTC 墙钟为准。

## 保存格式与重启行为

默认保存到 `user://world_time_state.json`，UTF-8 JSON，顶层 `schema_version` 为 2。包括日轮编号/相位/倍率/暂停状态、控制修订号、最近本地日轮起始计数和管理员日期覆盖。schema 1 存档会给新增可选字段赋默认值；缺失核心日轮字段、字段值无效或不支持的 schema 会被拒绝并记录警告。运行中每 30 个真实秒自动保存，管理操作后立即保存，退出时再保存。

保存文件包含上次单调锚点用于诊断，但启动恢复会无条件用新进程的 `Time.get_ticks_usec()` 重设它，因此服务器停止期间日轮不推进。正常日期在启动和运行时重新从现实 UTC 计算；固定的管理员日期覆盖则会恢复，直到显式清除。真实天气时间仍从 `get_real_utc_timestamp()` 取得。

## 自动化测试

```sh
godot --headless --path . --script res://tests/test_world_time_manager.gd
godot --headless --path . --script res://tests/test_world_time_client_sync.gd
```

测试使用伪 UTC 与伪单调时钟，不等待真实时间。覆盖默认 24×、150 秒推进一小时、3600 秒一轮、暂停、1/12/24/60 倍率、自然跨轮、手动跳时、Stockholm 午夜/跨月/跨年、春秋夏令时切换、保存恢复、快照往返及物理 delta 不受倍率影响。

## 未来服务器迁移

现在 `LocalAuthority` 是临时权威源。未来将同一组时间状态和快照放入服务器进程，由服务器独占 `set_*`、`pause/resume` 和持久化写入；客户端只应用服务器快照并以服务器提供的时间戳校正显示。服务器继续使用单调时钟推进日轮、UTC 墙钟确定现实日期；网络传输时不传递本地 monotonic anchor。现阶段没有网络连接或 RPC。

## F3 时间控制

现有 `BoatHUD` 的 F3 调试面板内新增“世界时间管理员”区块。面板显示世界日期、当前全局日轮序号、真实 Stockholm 日期内已记录的日轮起始序号、日轮时刻、倍率、暂停状态、权威来源及调试日期覆盖状态。

小时/分钟输入、06:00/12:00/18:00/00:00 快捷跳时、倍率选择、暂停/恢复、恢复 24×、日期覆盖和取消覆盖均通过 `WorldTimeControlPort` 请求方法。当前 `LocalWorldTimeControl` 转发至 `WorldTimeManager` 受控 API，面板不直接写入 `WorldTimeState`。管理操作立即由管理器持久化；隐藏 F3 面板不会撤销设置。

当前原型的本地适配器允许开发者操作。多人版本应替换 HUD 边界上的适配器：普通玩家端口只提供快照，管理员操作变为服务器请求，并由服务器根据已验证身份执行权限检查。F3 是否显示不能作为授权依据。

F3 联动测试会实例化正式主场景和 HUD，模拟面板显隐、倍率、暂停恢复、快速跳时、手动时间、闰日覆盖/取消，以及倍率和时刻的存档恢复：

```sh
godot --headless --path . --script res://tests/test_world_time_admin_controls.gd
```
