# Nordic 28 正式速度极曲线

## 正式船型与测量配置

Main 中使用 `scenes/boats/SailingBoat8m.tscn`。本次 Polar 测量从 SailboatLab 加载同一场景，并核实使用的正式资源为：

- 物理 Profile：`resources/sailing/sailboat_lab_profile.tres`
- 视觉 Rig：`resources/sailing/nordic28_visual_rig_profile.tres`
- 主帆 / Jib：17.66006 / 10.323244 m²，合计 27.983304 m²
- 船体纵向阻力：165 / 85；两片帆的 `induced_drag_factor` 均为 0.55
- 主帆和 Jib 展开率均为 100%；AUTO Reef 关闭；AUTO Trim 开启；发动机关闭
- 固定真风、零海流、静水采样（WaveSampler 保持运行），物理步长 1/60 s

扫描使用现有 `PolarTestRunner`、闭环舵控及正式稳定性判定。测试采用 480 physics ticks/s 与 time scale 8，Runner 检查实际物理步长仍为 1/60 s；这只加快墙钟执行，不扩大物理步长。

## 对称检查与测量结果

先在 12 kn / 90°、120°各测 PORT 与 STARBOARD。两组均稳定，航速差均不超过 5%，实际 TWA 误差低于 0.52°，横倾符号相反且幅度相同，因此通过本次镜像门槛，主网格测单侧并对称绘制另一侧。

正式网格为 4、8、12、16、20 kn，每档 0°–180°、10°间隔，共 95 个正式点。结果分类如下：

| TWS | 稳定有效点 | HEADING_FAILED | NO_FORWARD_PROGRESS |
|---:|---:|---:|---:|
| 4 kn | 10 | 6 | 3 |
| 8 kn | 12 | 7 | 0 |
| 12 kn | 13 | 6 | 0 |
| 16 kn | 13 | 6 | 0 |
| 20 kn | 13 | 6 | 0 |
| **合计** | **61** | **31** | **3** |

失败状态及原始测量值保留在数据中，图表仅绘制 `STABLE` 且有正向前进速度的点；遇到失败点会断开曲线，不将失败当作 0 kn，也不跨越缺口插值。验证过的对称数据允许镜像绘制。

| TWS | 最大有效 SOG | 最大点 TWA | 最佳迎风 VMG | 最佳顺风 VMG |
|---:|---:|---:|---:|---:|
| 4 kn | 0.813 kn | 120° | 无有效点 | 0.526 kn @ 180° |
| 8 kn | 2.179 kn | 120° | 0.164 kn @ 70° | 1.467 kn @ 180° |
| 12 kn | 3.631 kn | 120° | 0.408 kn @ 60° | 2.502 kn @ 150° |
| 16 kn | 5.079 kn | 120° | 0.602 kn @ 60° | 3.567 kn @ 150° |
| 20 kn | 6.458 kn | 120° | 0.655 kn @ 70° | 4.641 kn @ 150° |

VMG 来自测试器测得的速度向量相对真实风轴投影；迎风和顺风 VMG 分开记录。4 kn 没有足够有效迎风点，因此不显示最佳迎风角。

## 数据与追溯

- 正式数据：`resources/sailing/nordic28_polar.json`
- 原始 Runner 输出、对称校验与清单：`docs/sailing/polar_nordic28_official/nordic28_polar_20261029T125403_72746/`
- Polar run ID：`nordic28_polar_20261029T125403_72746`
- Runner 网格 run ID：`polar_2026-10-29_12-56-08_240915`
- 发布配置指纹：`abc7434f93e07b0e098d87f582203f60482f12949c8703751719a81331d98c83`
- 网格 Runner 指纹：`5cd63eaa81fb7c7aecc7a62efe7d445d0f453a86319b838ea13c25009052dbc9`

JSON 保存船型场景、运行时间、风速/风角网格、单位、对称验证、来源 run ID、配置指纹和 95 个结果。每个结果还记录展开率、AUTO Reef、AUTO Trim、发动机状态和失败原因。清单同时保存参与配置和测试代码的 SHA-256。

## 主游戏操作

驾驶 Nordic 28 时，在右侧帆船航行仪表控制区域点击 **“速度极曲线”** 打开中央 Polar 面板；点击 **“关闭 ×”** 或按 **Esc** 返回驾驶画面。图中 0° 在上方表示迎风，±90°在两侧表示横风，180°在下方表示顺风；半径为 kn。五档风速使用不同颜色，图例标出风速，环线标出速度。

图中当前船舶标记使用实际 TWA 和当前 STW（当前项目没有水流，因此 STW 与 SOG 相同），对读数做轻量平滑。若当前 TWS 落在已测风速档之间，会显示仅在上下相邻档及同角度两侧均为有效数据时才计算的虚线参考曲线；不在已测风速范围外推。缩帆时会提示“当前已缩帆，曲线为 Nordic 28 满帆参考性能”，并显示主帆/Jib 实际展开率。静态曲线和测量索引在读入时缓存；当前位置随航行更新，虚线参考线和最佳角度缓存按 0.1 kn 风速档更新。

面板也会从有效数据中显示当前风速下的最快点及可用的迎风、顺风最佳 VMG 角度。VMG 可用区域不足时不显示对应建议。

## 修改文件

- `scripts/sailing_polar_chart.gd`：轻量自绘极坐标曲线、有效点筛选、镜像/插值、当前位置和建议点。
- `scripts/boat_hud.gd`：Main 航行仪表入口、开关面板和实时数据。
- `scripts/polar_test_runner.gd`、`scripts/polar_data_exporter.gd`：在 Polar 结果中附加帆展开率及 AUTO Reef 状态。
- `tests/run_nordic28_official_polar.gd`：正式资源校验、舷侧对称探针、可恢复网格扫描和正式数据生成。
- `tests/test_nordic28_polar_ui.gd`：Main 场景 UI smoke。
- `resources/sailing/nordic28_polar.json`：当前正式数据。
- `docs/sailing/polar_nordic28_official/`：可追溯的扫描原始产物和运行清单。

## 验证与人工检查

已通过：

- `godot --headless --path . --editor --quit`：脚本/资源扫描完成，退出码 0。
- `godot --headless --path . --script res://tests/run_nordic28_official_polar.gd -- --validate-only`：正式场景与 Profile、95/180 工况网格校验通过。
- `godot --headless --path . --script res://tests/test_nordic28_polar_ui.gd`：Main 场景加载数据、打开和关闭 Polar 面板、缩帆说明与实时展开率 smoke 通过；数据校验为 95 条。
- 数据检查：95 条记录，无非有限 SOG/STW；全部满帆、AUTO Reef 关闭、AUTO Trim 开启、发动机关闭；状态计数与质量门一致。
- `git diff --check`：通过。

Headless smoke 不能验收实际绘图外观。本次尝试在 Mac Forward+（Apple M2 Pro）启动游戏，但当前环境无法捕获游戏窗口，因此没有宣称图形验收通过。请在 Main 中重点人工确认：不同分辨率下的极坐标图和图例是否完整；0°/90°/180°方向是否直观；无效点造成的断线是否清楚；当前标记和缩帆提示是否易读且不遮挡关键驾驶信息。

Headless Main 退出时还有一条 RendererDummy shader RID 泄漏提示，未伴随 Polar 脚本错误；编辑器资源扫描还提示仓库内已有的重复 `.translation` UID。二者不影响本次数据校验或 UI smoke，但应与实际 Forward+ 运行画面分别观察。
