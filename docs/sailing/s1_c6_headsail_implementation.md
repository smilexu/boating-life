# S1-C6：独立前帆 Jib 实现与验证

## 结论

SailboatLab 已加入一张独立三角前帆。它使用独立帆角、帆面积、压力中心和空气动力参数，受力直接施加在现有帆船 `RigidBody3D` 上。主帆仍使用原来的空气动力接口；两张帆共用一份每物理步取得的真风样本，但分别按自己的压力中心速度计算视风。

在静水、由真实船舵控制目标 TWA 的 120 秒测试中，双帆在选测的 5–12 m/s 横风/斜后风工况均达到 `steady`，比单主帆 SOG 高约 24%–31%。这些是 SailboatLab 原型数据，不代表真实船型性能。前帆单独使用在 5 和 8 m/s、TWA 90°时达到舵角上限，不能稳定保持目标航向，显示前帆不能替代完整平衡帆装。

## 实现

### 前帆几何与资源

8 米原型的 Jib 参数保存在 `SailboatLabProfile`，不从 GLB 网格推导：

| 参数 | 原型值 |
|---|---:|
| 名义帆面积 | 5.16 m² |
| Head | `(0, 4.95, -0.75)` m |
| Tack | `(0, 0.65, -3.55)` m |
| 中立 Clew | `(0, 0.65, -1.15)` m |
| 压力中心基准 | 中立三角形形心 `(0, 2.083, -1.817)` m，再加 Resource 偏移 |
| Clew 位移对压力中心的跟随比例 | 1/3 |
| 角度限位 | ±1.222 rad（约 ±70°） |
| 帆角变化速度 | 0.52 rad/s |

原候选 Tack/Clew 高度为 0.62 m，落在测试甲板顶面 0.63 m 以下。实现将其上调到 0.65 m，Head 保持不变，名义三角面积从约 5.196 m² 调整为 5.16 m²。三角面积以当前顶点用叉积计算；该面积是这张原型帆的基准值，不是实测船帆数据。

`HeadsailVisual` 是船体 `VisualRoot` 下的双面低多边形网格。Head 与 Tack 固定，Clew 在 Tack 周围的水平面内转动并保持帆脚长度；网格顶点在实际帆角改变时更新。它不创建刚体、不参与碰撞，也不模拟布料。主帆与前帆三角形在主帆 ±80°、前帆 ±70°，每 5° 采样的 957 组 SAT 检查中未发现相交；帆脚保持在甲板上方。

有一项明确的视觉简化：前帆实体的物理面积固定为 5.16 m²，但三顶点平面网格因 Clew 横移而改变几何面积；CSV 中从 0° 的 5.16 m² 到 ±70° 的 6.049 m²。物理帆面积没有随之变化。中间角度的平面三角形因此会有一定视觉“拉伸”。如人工验收认为明显，后续可改为能保持面积的轻量弯曲/多顶点帆面；本轮未加布料模拟。

### 空气动力和刚体施力

`SailboatAeroMath.calculate_sail_forces()` 保持主帆既有语义，并委托给共享的 `calculate_sail_forces_for_chord()`。通用函数接收实际帆弦的局部 XZ 方向；Jib 用 `Clew - Tack` 作为帆弦，避免把主帆 Boom 角度解释套到无 Boom 的前帆。

每个固定物理步：

1. 在主帆中心查询一次 `WindField`。
2. 对主帆和前帆分别按各自压力中心计算点速度 `V_com + ω × r`，再计算局部视风。
3. 两张帆各自以配置面积、攻角、CL/CD、迎风失风和反吹衰减参数计算升力及阻力。
4. 各自使用独立的刚体施力偏置施力，并分别记录局部力、偏航力矩及横倾力矩。

Jib 复用现有有界升阻模型。小攻角升力、失速衰减、迎风失风曲线均为连续计算；反吹侧降低升力至配置的保留比例，阻力仍沿空气流向作用。当前 Jib 与主帆使用相同的基础系数起点，但在 Resource 中分别配置。没有加入帆间尾流增强/遮挡或 CFD。

关闭前帆后，Jib 力及记录的横倾/偏航力矩归零、隐藏前帆网格，主帆、水动力和舵不变。调试重置时角度回到中立。关闭开关可以用于主帆/双帆基线比较。

## 操作与 HUD

- SailboatLab 现有“风与主帆”调试页增加前帆开关、角度滑块和受力诊断；没有增加新 Tab。
- `J` 将前帆目标角减少 10°，`L` 增加 10°；已检查 `project.godot` InputMap 和现有脚本，没有既有 J/L 绑定。实际帆角受 ±70° 限位和 0.52 rad/s 速率限制平滑跟随。
- 也可通过 `set_target_headsail_angle()`、`get_target_headsail_angle()`、`get_actual_headsail_angle()` 和 `set_headsail_enabled()` 调用；自动操帆尚未实现。
- 右上角航行仪表增加 JIB 启用状态、实际/目标角和与主帆颜色区分的方向线。其读数来自物理状态快照。

## 对照测试

运行器复用 C5e 的 SailboatLab 刚体、真实水动力舵控制器和已发布的主帆角。每组先将船、帆、风和水面复位；模式为 `main_only`、`jib_only`、`dual`。静水无流；单帆/双帆长测从静止开始，恒风及目标 TWA 持续 120 秒。受控航向误差和舵角受限均纳入状态分类。

下表为 120 秒稳定区间的平均值。`Vlong` 是船体局部 -Z 前进速度，SOG 是水平速度大小；两者分开列出。双帆 Jib 角是测试配置，不是自动寻优结果。

| TWS / 目标 TWA | 主帆角 / Jib 角 | 单主帆 SOG → 双帆 SOG | 双帆增幅 | 双帆 Vlong | 平均横倾：单帆 → 双帆 | 双帆平均舵角 | 双帆状态 |
|---|---:|---:|---:|---:|---:|---:|---|
| 5 m/s / 90° | -60° / -45° | 1.179 → 1.545 kn | +31.0% | 0.791 m/s | 1.27° → 1.80° | 10.33° | steady |
| 8 m/s / 90° | -60° / -45° | 2.342 → 2.981 kn | +27.3% | 1.529 m/s | 3.34° → 4.77° | 6.91° | steady |
| 8 m/s / 120° | -70° / -60° | 2.572 → 3.261 kn | +26.7% | 1.677 m/s | 1.61° → 2.32° | 0.09° | steady |
| 12 m/s / 90° | -60° / -45° | 3.956 → 4.911 kn | +24.1% | 2.521 m/s | 7.54° → 10.67° | 4.21° | steady |

这四组双帆均达到 `steady`：末段航向误差分别约 2.07°、1.38°、0.02°、0.84°。SOG 与 Vlong 均上升，表现不是单靠横向漂移获得。测试记录到独立 Jib 推进分量约 79、197、223、425 N；其偏航与横倾力矩均非零，因此它参与平衡，而不是简单把面积叠到主帆作用点。

Jib-only 不是推荐航行配置：5/90 与 8/90 两组被标为 `control_limited`，平均舵角约 35°达到上限，航向误差分别约 35.39°和 9.88°；8/120 可稳定，但速度低于单主帆。可见前帆单独施力会明显改变帆压中心与偏航平衡，实际用途应与主帆共同调帆。

8 m/s、TWA 90°的 25 秒短时 Jib 角筛选中，主帆固定 -60°，Jib -60°测得 2.953 kn，-45°为 2.905 kn，0°为 2.310 kn。此扫描标记 `screen_only`，不是稳态最优结论；尚未对 -60° 做对应 120 秒复测，所以运行器默认 -45° 的长测不能用于声称该 Jib 角已经最优。

## 数据文件

所有 CSV 位于 `docs/sailing/c6_data/`。速度为 kn 或 m/s，力为 N，力矩为 N·m，时间为秒，运行耗时为 μs。角度以 ° 记录；采样条件和状态均在每行保留。

| 文件 | 内容与解释 |
|---|---|
| `headsail_geometry_and_force.csv` | 7 个帆角下的名义/网格三角面积、三顶点和形心。 |
| `single_vs_double_sail.csv` | 20 秒筛选及 120 秒长测；单帆、前帆单独、双帆的 SOG、Vlong/Vlat、实际 TWA、AWS、横倾、侧滑、航向误差、舵角、各帆力/力矩、前进位移、差值、耗时和状态。共 51 行：27 行筛选、14 行控制受限、10 行稳定。筛选行明确不是稳定航速。 |
| `double_sail_trim_scan.csv` | 8 m/s、TWA 90°下 5 个 Jib 角的 25 秒筛选，主帆保持 -60°；状态为短筛选，不代替长测。 |
| `double_sail_force_torque.csv` | 各模式的平均主帆/Jib 前向力、Jib 横向力及帆、龙骨、舵偏航力矩。 |
| `sail_performance_comparison.csv` | 静水矩阵各模式总物理、气动和 Jib 计算耗时，以及每步 WindField/WaveSampler 查询次数。 |
| `sail_performance_dynamic_waves.csv` | 8 m/s、TWA 90°的 20 秒动态波浪单帆/双帆性能采样。 |

离线命令：

```sh
godot --headless --path . -s tests/run_sailboat_s1_c6_headsail.gd -- --phase=all
```

支持 `geometry`、`matrix`、`long`、`trim`、`wave_performance` 分阶段选项。完整运行本轮 58 组，报告用时约 298.5 秒；运行器只覆盖场景实例上的测试状态，不修改 Resource 文件。

## 性能

动态波浪 headless 20 秒物理计时：

| 配置 | 总物理代码段 avg / P95 | 帆气动 avg / P95 | Jib 部分 avg / P95 | WindField / WaveSampler 每步 |
|---|---:|---:|---:|---:|
| 单主帆 | 238 / 285 μs | 15 / 22 μs | 2 / 4 μs | 1 / 4 |
| 双帆 | 241 / 293 μs | 22 / 30 μs | 9 / 13 μs | 1 / 4 |

该次 headless 内部计时观察到总代码段约增加 3 μs 平均、8 μs P95，气动部分约增加 7 μs 平均；Jib 单独部分平均约 9 μs。静水扫描中，单帆总段约 59–64 μs、双帆约 65–74 μs。微秒计时会受调度和采样窗口影响，只适合本机 headless 对比；没有据此声称 Forward+ GPU 帧耗时、M2 性能达标或 Windows 性能达标。

## 验证

- `tests/test_sailboat_headsail.gd`：46 项通过；包含 Jib 面积/形心、两侧镜像、错误侧升力衰减、零风/迎风失风、帆角限位与限速、视觉 Clew 方向、受力中心力矩、禁用后单帆力合计、单 WindField 查询与静水零 WaveSampler 查询，以及 957 组主帆/Jib 面片交叠采样。
- `tests/test_sailboat_aerodynamics.gd`：321 项通过；主帆接口保留，气动和查询预算回归通过。
- `tests/test_sailboat_hydrodynamics.gd`：60 项通过。
- `tests/test_sailboat_buoyancy.gd`：87 项通过；保留四点浮力及动态波浪测试。
- `tests/test_sailboat_damping_policy.gd`：17 项通过。
- `tests/test_sailboat_navigation_instrument.gd`：40 项通过。
- `tests/test_sailboat_polar_math.gd`：12 项通过。
- `tests/test_wind_field.gd`：23 项通过。
- `tests/run_sailboat_s1_c5e_polar.gd -- --phase=smoke`：3 个短场景通过；仅为 C5e 测试器启动回归，不是新的稳定极曲线。
- `tests/run_sailboat_s1_c6_headsail.gd -- --phase=geometry` 和完整 `--phase=all` 均以退出码 0 完成。
- `git diff --check` 通过。

这些自动化与 headless 测试不替代可视化验收。尚未在 macOS M2 或 Windows Forward+ 下人工观察 Jib 网格、阴影、远景轮廓、横倾观感及实际帧率。动态海浪结果只覆盖 20 秒组合压力样本，不是双帆动态海浪的 120 秒稳态航速。

## 文件变更

- 船型 Resource：`resources/sailing/sailboat_lab_profile.gd`、`resources/sailing/sailboat_lab_profile.tres`。
- 场景与前帆网格：`scenes/SailboatLab.tscn`、`scripts/headsail_triangle_visual.gd`。
- 空气动力与帆船运行时：`scripts/sailboat_aero_math.gd`、`scripts/sailboat_lab_body.gd`。
- 调试界面和导航仪表：`scripts/sailboat_lab_debug_panel.gd`、`scripts/sailboat_navigation_instrument.gd`。
- 新增测试：`tests/test_sailboat_headsail.gd`、`tests/run_sailboat_s1_c6_headsail.gd`。
- 回归适配：`tests/run_sailboat_s1_c5c_drag_diagnostics.gd` 将旧单帆诊断显式设为关闭前帆，保护历史基线；C5e 测试器使用独立的 Jib 力矩遥测列。
- 报告和数据：本文件及 `docs/sailing/c6_data/*.csv`。

## 当前限制与后续建议

双帆在受控的横风/斜后风样本中增加了推进，并将测试舵角维持在限位以内；横倾也随风速和帆力增加，12 m/s 横风双帆平均横倾约 10.67°。这些数值尚不能说明更强风况下的倾覆安全性。当前没有帆间尾流，气动系数是原型调参值；长测只覆盖 TWA 90°、120°的精选工况，45°与其他角度主要是短筛选。

目标角/实际角接口、Resource 参数、Jib 空气动力、独立作用中心与遥测已经为未来 AutoSailTrim 提供可调用基础，但还不建议直接进入自动操帆：应先在 Forward+ 下确认几何效果，并补齐关键风角下双帆的长时稳态和左右舷人工操帆验收。当前不实现自动操帆，不改正式动力船、天气、WindField、WaveSampler、浮力或水动力参数。
