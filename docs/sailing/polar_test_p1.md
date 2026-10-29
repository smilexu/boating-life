# Sailing Polar System · P1 测试工具

## 目标与边界

P1 在 SailboatLab 中增加通用 Polar 自动测试入口。测试数据来自选中帆船场景的真实 `RigidBody3D`、现有帆力/水动力/浮力和 AUTO Trim；测试控制器只通过现有船舵目标角接口闭环保持 TWA。

本轮没有运行完整 180 个默认工况，没有创建正式航速表，也没有修改帆船物理、AUTO Trim 曲线、发动机推力或天气默认行为。项目目前登记了一艘可测帆船 `SailingBoat8m.tscn`；后续新增符合 Polar 船舶接口的场景时，将其路径加入 PolarTestProfile 的 `boat_scene_paths` 即可出现在场景选择列表。

## 工具结构

| 文件 | 职责 |
|---|---|
| `scripts/polar_test_profile.gd`、`resources/sailing/polar_test_profile.tres` | 船型场景登记、风速/TWA 网格、稳定性阈值、固定风向、控制器与固定物理步长配置。 |
| `scripts/polar_test_runner.gd` | 工况生成、场景选择、环境隔离、刚体初始化、真实舵角闭环、进度、超时、中断、恢复和失败工况重跑。 |
| `scripts/polar_test_math.gd` | 带符号 TWA、目标 HDG、真实船舵 PD 命令、目标航迹 VMG 和侧滑角纯函数。 |
| `scripts/polar_stability_detector.gd` | 计算稳定窗口指标并分类结果，不修改船体状态。 |
| `scripts/polar_data_exporter.gd` | CSV、JSON、摘要、checkpoint 写入和最新 checkpoint 读取。 |
| `scripts/sailboat_lab_debug_panel.gd` | F3 内的 Polar 自动测试页和实时状态。 |
| `scripts/sailboat_lab.gd` | 在 SailboatLab 内替换所选帆船实例，并将同一个 WaveSampler 的相位锚点重新接到当前船体。 |
| `scripts/wave_sampler.gd` | 提供切换测试船时更新现有波浪相位锚点的轻量接口，不创建第二个采样器。 |
| `scenes/SailboatLab.tscn` | 注册 PolarTestRunner 和独立 PolarTestProfile。 |
| `tests/test_polar_test_p1.gd` | 纯函数、稳定性分类和角度环绕单元检查。 |
| `tests/run_polar_test_p1.gd` | 短时真实刚体集成烟雾测试，包括风场、镜像、重复性、发动机隔离及中断恢复。 |
| `tests/sailboat_polar_math.gd` | 将既有 C5e 数学测试转为共享 helper 的兼容包装。 |

PolarTestRunner 和 Exporter 的配置指纹包含测试器/导出器本身、稳定判定与数学 helper 源码，确保恢复时测试方法版本也一致。

测试工具只挂在 `scenes/SailboatLab.tscn`，没有加入 Main 或 I 键船舶菜单。

## 船型选择和共享物理

测试页的船型下拉列表从 PolarTestProfile 的 `boat_scene_paths` 读取。选择时加载对应 PackedScene，检查其真实帆船测试 API，然后在相同 SailboatLab 环境节点下替换当前船体。切换会取消旧刚体碰撞与处理，复用已有 WindField、WaveSampler、天气/海图上下文，不创建第二套环境服务。调试面板、航行仪表、runner 和海浪相位锚点随新船体更新。

当前列表只含 `res://scenes/boats/SailingBoat8m.tscn`。通用接口要求船体提供导航/诊断快照、真实舵目标角、AUTO Trim、测试风覆盖和重置接口；不符合接口的场景会被拒绝。

## 风场、静水和初始条件

- 使用 SailboatLab 自己的 WindField；`set_lab_test_wind()` 会拒绝由 `WeatherStateController` 管理的正式风场。
- 每个工况设置固定 TWS 和风从方向（默认 180°），使用固定 seed、零阵风强度、零风向变化，并将测试风场时钟固定在 0 秒。
- F3 Polar 页输入风速使用节，运行时转换为 m/s 传给现有 WindField。
- 静水时仅把 SailboatLab 私有 WaveSampler 的 `wave_strength` 设为零；帆船仍保持动态波浪采样开关开启，四个浮力采样点继续调用同一个 WaveSampler。水流设置为零。工况结束后恢复原风、WaveSampler 振幅和浮力设置。
- 每个工况通过现有 `reset_to_neutral()` 回到相同原点、水平姿态和零初速，并把船首设为目标方向。没有在正常运行中写入船速、角速度或航向。测试将辅助发动机瞬时设为 OFF/空挡，保留油箱余量；AUTO Trim 开启。
- 测试运行器逐步检查刚体报告的 `physics_delta_s` 与配置的固定 1/60 s 差异；运行工具本身不会改变 `Engine.time_scale` 或物理频率。

## TWA 控制器

项目沿用真风“来向”、0°北、90°东和左舷负 TWA 约定。目标船首罗盘角为：

```text
target_hdg = wrap_360(wind_from_bearing - signed_target_twa)
```

Godot 刚体 yaw 与罗盘 HDG 符号相反，因此初始化时把目标 HDG 转成现有实验重置接口所需的 Godot yaw。闭环每个物理步读取实际 HDG 和偏航角速度，并以 `rudder_command = clamp(P × heading_error - D × compass_yaw_rate)` 计算目标舵角；命令再通过 `set_target_rudder_angle()` 输入，实际舵角仍受船型机械限位与转动速率约束。初始 P/D 默认与既有 C5e 测试控制器相同（5.0 / 3.0），限位上限取船体导航快照和 Profile 配置中的较小值。

VMG 是世界水平速度在目标航迹方向上的投影，不以 SOG 代替。当前项目无水流，且 runner 将水流设为零，所以导出的 STW 与 SOG 相同；报告和 JSON 元数据对此作了说明。侧滑角用船体局部横向/纵向速度计算，低于 0.15 m/s 时不可可靠定义，导出为 JSON `null`、CSV 空值。

## 稳态判定

默认 Profile：最短预热 60 s；稳定窗口 30 s；稳定后采样 30 s；单工况超时 300 s。判定阈值可在 Profile 中配置：

- 窗口内平均绝对 TWA 误差 ≤5°，平均绝对 HDG 误差 ≤5°。
- 舵角机械限位饱和比例 ≤20%。
- SOG 标准差 ≤0.20 m/s；前后半窗口平均速度差 ≤0.12 m/s。
- 平均绝对偏航角速度 ≤4°/s。
- 目标航向保持且以上稳定性条件满足，但船体纵向速度 ≤0.10 m/s 时，分类为 `NO_FORWARD_PROGRESS`，而不是有效 Polar 点。

输出状态包括 `STABLE`、`NO_FORWARD_PROGRESS`、`HEADING_FAILED`、`UNSTABLE`、`TIMEOUT`、`INVALID` 和 `INTERRUPTED`。无法维持目标航向不会被写成零航速的正常数据；低速漂移也会单独标记。

## 批量、保存和恢复

F3 页支持船型、逗号分隔的 TWS 列表、TWA 起止角/步长、左右舷勾选、开始、安全中断、恢复 checkpoint 和重跑失败工况。0°、180°对称边界每个 TWS 只跑一次。默认网格为 5 个 TWS × 19 个绝对 TWA 网格点（两端各一次、17 个内部角度左右舷各一次），即 180 个工况。UI 不会自动运行；本轮验证只选择少量测试条件。

每个 run 有独立 run_id，输出到：

```text
user://polar_tests/<run_id>/polar_results.csv
user://polar_tests/<run_id>/polar_results.json
user://polar_tests/<run_id>/polar_summary.json
user://polar_tests/<run_id>/polar_checkpoint.json
```

CSV 包含工况 ID、船场景、配置哈希、Godot 版本、测试条件、实测 TWS/TWA/AWS/AWA、SOG/STW/VMG、纵向速度、横倾/侧滑、速度标准差、航向误差、平均舵角/饱和率、两帆角度与前向力、模拟时长、样本数和状态/失败原因。JSON 保存同一数据及工况/运行元数据；摘要记录状态计数和有效 STABLE 速度均值。

配置指纹使用 SHA-256，包含所选船舶场景文件、船型 Profile 的存储值和 `.tres` 源、Godot 版本、运行配置，以及真实帆船体、帆气动、水动力、浮力、AUTO Trim、辅助发动机、导航、WindField、WaveSampler 和 Polar 测试/导出/判定脚本内容。checkpoint 保存该指纹、工况、结果、运行目录和下一工况索引。恢复/失败重跑时若船型或指纹不匹配会拒绝操作；已完成结果不会被覆盖。用户安全中断时当前工况标为 `INTERRUPTED`，恢复会重跑这个工况，而不是复制出第二条记录。

## 已运行验证

运行命令：

```sh
godot --path . --headless --script res://tests/test_polar_test_p1.gd
godot --path . --headless --script res://tests/test_sailboat_polar_math.gd
godot --path . --headless --script res://tests/run_polar_test_p1.gd
git diff --check
```

验证结果：

- Polar 数学/稳定性 helper：10 项通过。
- 历史 `sailboat_polar_math` 回归：12 项通过；旧 C5e 调用通过兼容包装继续使用共享数学实现。
- 真实刚体 smoke 测试完成 7 个小批次，未执行全量网格。测试时使用 headless-only 的 8×时间倍率与 480 Hz 物理频率；runner 对每个真实刚体物理步检查仍为 1/60 s。
- 12 kn、±90°：Port/Starboard 均产生分类结果；短 smoke 窗口下 SOG 约 1.012/1.012 kn，横倾约 −2.27°/+2.27°。因为该测试将预热/稳定/采样窗口缩短为数秒，这不是正式稳态 Polar 数据。
- 12 kn、TWA −20°：分类为 `NO_FORWARD_PROGRESS`，测得 TWA −20.38°，平均船体纵向速度 −0.048 m/s；不是正常稳定速度点。
- 同一 12 kn、90°短测重复 3 次，平均 SOG 为 1.011501 kn，极差 0.0000 kn。
- 各工况记录并确认 AUTO Trim 已开启；engine OFF 油量不变；静水模式仍检查到每步 4 次 WaveSampler 和 1 次 WindField 查询。
- 中断写入 checkpoint、错配置恢复被拒绝、配置一致时恢复并重跑中断工况均通过。

以上是 Headless 物理/工具测试，不是 Forward+ UI 或图形帧率验收；没有运行完整 C1–C8 回归，也没有做 Nordic 28 全极曲线扫描。

## 人工验收步骤

1. 启动 SailboatLab：`godot --path . res://scenes/SailboatLab.tscn`。
2. 按 F3，打开“Polar 自动测试”页，确认下拉列表显示当前注册的 `SailingBoat8m`。
3. 将 TWS 设为 `12`，TWA 起止都设为 `90`，勾选左右舷，点击开始。观察当前工况、船速、实测 TWA、舵角和稳定性状态；测试期间其它调参页会禁用。
4. 检查 `user://polar_tests/<run_id>/` 的 CSV、JSON、摘要和 checkpoint。再分别运行单侧 TWA `20`，确认无法前进时显示对应状态及失败原因。
5. 使用一个较长工况点击安全中断；不改变船型、风速/TWA 范围和相关 Profile 的前提下恢复。故意改变一个 TWS 后恢复应被拒绝。
6. 在 SailboatLab 普通航行页确认测试结束后 WindField、海浪振幅、浮力采样和键盘输入恢复。

## 已知限制

- 当前只有 Nordic 28 一个已登记帆船场景，仍需人工 Forward+ 验证 UI 外观和多分辨率布局。
- Heading PD 增益是可配置测试初值，不是对所有船型优化的掌舵器；如果舵角长期饱和，结果会标为航向失败，不应当作正式性能点。
- 由于没有水流模型，STW 暂以 SOG 代表。VMG 是沿目标航迹方向的速度投影。
- P1 只提供数据采集和可靠性分类，不绘制游戏 Polar 图、不写正式船舶数据，也不调校物理。
- 默认完整网格约 180 个工况；请等 P2 再启动 Nordic 28 全量测试。
