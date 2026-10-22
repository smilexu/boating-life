# S1-C8-Fix：Main 前帆视风坐标修复

## 结论

根因确认：Jib 视风点速度使用的质心力臂把船体局部点变换成了世界方向偏移后，又减去世界空间质心绝对位置。Main 位于公里级世界坐标时，这产生了约 16.3 km 的伪力臂。角速度叉乘该伪力臂后，Jib 点速度和视风被放大，形成“视风增大 → 动压/帆力增大 → 刚体角速度增大 → 视风继续增大”的正反馈。船体仅倾斜约 4.32°时便出现数值异常，因此这是坐标空间错误，不是扶正力不足。

修复后，Jib 与主帆、龙骨、船舵和四个浮力点都使用同一 helper 计算从**有效质心**到局部作用点的世界空间力臂。`apply_force()` 的第二个参数仍使用相对刚体原点的世界方向偏移；世界绝对采样点则继续使用 `body_origin + offset`。未调整任何物理参数。

## 原错误与修复

`SailboatLabBody` 在 `_ready()` 中将质心模式设为 `CUSTOM`，并从船型 Profile 设置 `center_of_mass`。本船有效局部质心是 `(0, -0.65, 0)` m；并非由 Godot 自动计算的质心。因此点速度计算应使用 `RigidBody3D.center_of_mass` 这一局部值。

错误式：

```gdscript
body_basis * headsail_pressure_center_local - center_of_mass_world
```

`body_basis * headsail_pressure_center_local` 是**世界方向偏移**，而 `center_of_mass_world` 是**世界绝对点**；两者不能相减得到质心力臂。

修复后统一通过 [sailboat_lab_body.gd](/Users/smixu1/dev/boat-life-simulator/scripts/sailboat_lab_body.gd:45) 中的 helper：

```gdscript
world_arm_from_local_point(point_local, center_of_mass, body_basis)
    = body_basis * (point_local - center_of_mass)
```

Jib 将这个世界空间质心力臂传给 `calculate_apparent_wind()`；该函数只在内部执行一次 `angular_velocity.cross(r)`，没有重复加入角速度项。`calculate_apparent_wind()` 的参数契约见 [sailboat_aero_math.gd](/Users/smixu1/dev/boat-life-simulator/scripts/sailboat_aero_math.gd:30)。

用户提供的异常快照显示：错误力臂约 16.3 km、Jib 视风约 396 m/s、动压约 95,827 Pa、帆力约 268,856 N。修复后 8 m/s 均匀横风平移试验中，Jib 力臂为 3.46376 m，Jib 最大视风约 7.95–7.97 m/s、最大力约 119.8–120.3 N。两组数值来自不同模拟阶段；后者证明当前大坐标测试不再引入公里级力臂或异常放大。

## 坐标空间审计

| 用途 | 表示与计算 | 结论 |
|---|---|---|
| 主帆/Jib 压力中心 | `LOCAL_POINT`；由实际帆角和帆形算出 | 两者均从有效局部质心计算 `WORLD_ARM_FROM_COM`，送入视风函数 |
| 风场查询点 | `WORLD_POINT = body_origin + body_basis * local_point` | 正确；WindField 接收绝对世界位置 |
| 主帆、Jib、龙骨、船舵施力位置 | `WORLD_OFFSET_FROM_BODY_ORIGIN = body_basis * local_point` | 正确；`apply_force(force, position)` 的 position 不是绝对世界坐标，也不是质心力臂 |
| 龙骨、舵点速度 | `linear_velocity_world + angular_velocity_world × WORLD_ARM_FROM_COM` | 现统一使用 helper；水流速度再转换到船体局部空间 |
| 浮力采样点 | `WORLD_POINT = body_origin + world_offset`；点速度单独使用 `WORLD_ARM_FROM_COM` | 正确；海浪采样使用世界绝对点，`apply_force` 使用相对原点偏移 |
| 力矩遥测 | `(point_local - COM_local) × force_local` | 两边均为局部坐标；输出的 yaw/roll 分量是船体局部轴分量，不宣称为世界轴分量 |
| 船体阻力 | 世界速度减水流后转换为船体局部速度 | 坐标顺序一致；异常日志中的零向量归一化发生在刚体状态已经发散之后，是次生告警 |

代码位置：Jib/主帆视风及施力在 [sailboat_lab_body.gd](/Users/smixu1/dev/boat-life-simulator/scripts/sailboat_lab_body.gd:490)；龙骨和舵在 [同一脚本](/Users/smixu1/dev/boat-life-simulator/scripts/sailboat_lab_body.gd:609)；浮力与 WaveSampler 在 [同一脚本](/Users/smixu1/dev/boat-life-simulator/scripts/sailboat_lab_body.gd:724)。Jib 的世界空间质心力臂也加入只读 debug/navigation 快照，便于现场核验。

## 平移不变性试验

使用 SailboatLab 共用的生产刚体与气动力实现、静水、零海流、零阵风、固定 8 m/s 来风、相同帆角和刚体初值，分别放在世界 `(0,0,0)`、`(10,0,-10)` km、`(20,0,-20)` km。风向量三个位置均为 `(8,0,0)` m/s。即时采样包含重置后的一次物理步；这一步中实际刚体线/角速度已有轻微变化，因此该表的亚百分比差异不能全部归因于浮点精度。测试同时记录了速度，避免把状态差异误报成纯坐标误差。

| 世界偏移 X/Z | Jib COM 力臂 | Jib AWS / 合力 | Jib 偏航 / 横摇力矩 | 主帆 AWS / 合力 | 主帆偏航 / 横摇力矩 |
|---:|---:|---:|---:|---:|---:|
| 0 / 0 m | 3.46376 m | 6.90444 m/s / 80.071 N | -138.064 / -205.080 N·m | 6.78782 m/s / 451.557 N | 136.786 / -1106.734 N·m |
| 10,000 / -10,000 m | 3.46376 m | 6.87430 m/s / 80.577 N | -138.832 / -206.295 N·m | 6.74062 m/s / 448.253 N | 133.149 / -1111.092 N·m |
| 20,000 / -20,000 m | 3.46376 m | 6.87558 m/s / 80.477 N | -138.672 / -206.048 N·m | 6.74305 m/s / 448.261 N | 133.442 / -1109.745 N·m |

Jib 力臂与局部几何计算完全相符，三个位置没有随坐标距离增加。Jib AWS、合力和力矩变化小于约 0.8%；主帆力矩的最大差异约 2.7%，主帆横摇力矩约 0.4%。差异不随位置距离单调放大。初始读数在重置后的一次物理步取得，实际船体线/角速度已有小幅变化；测试对主帆力矩使用 3% 比例容差，并把这些值完整保留在 CSV，而不是把物理状态变化误称为坐标浮点误差。独立的 5 秒受控航行结果也接近：SOG 为 `0.61588 / 0.61748 / 0.61747 m/s`，最大倾角 `3.6043 / 3.6096 / 3.6096°`，最大 Jib AWS `7.9453 / 7.9710 / 7.9710 m/s`，最大 Jib 力 `120.28 / 119.81 / 119.81 N`。该差异远小于原错误造成的公里级力臂和数十万牛帆力。逐项数据见 [translation_invariance.csv](/Users/smixu1/dev/boat-life-simulator/docs/sailing/c8_data/translation_invariance.csv)。

## Main 长时回归

以 Main 帆船出生点、正式 WindField、Main WaveSampler、AUTO 操帆和动态海浪运行模拟 600 秒。Headless 通过提高物理 tick 和 time scale 运行固定 60 Hz 模拟步，不代表现实墙钟 10 分钟，也不构成 Forward+ 视觉测试。

| 模拟时间 | 真实风速 | Jib AWS | Jib 力 | SOG | 倾角 |
|---:|---:|---:|---:|---:|---:|
| 60 s | 4.41 m/s | 4.21 m/s | 93.0 N | 0.410 m/s | 2.02° |
| 180 s | 4.98 m/s | 4.69 m/s | 115.3 N | 0.847 m/s | 1.33° |
| 300 s | 4.59 m/s | 4.27 m/s | 95.1 N | 0.868 m/s | 0.64° |
| 420 s | 4.28 m/s | 3.91 m/s | 79.6 N | 0.748 m/s | 0.59° |
| 600 s | 4.21 m/s | 3.82 m/s | 75.7 N | 0.852 m/s | 0.89° |

600 秒全部完成。全程最大值：SOG `0.922 m/s`、倾角 `3.727°`、Jib AWS `5.257 m/s`、Jib 力 `145.1 N`、主帆力 `290.4 N`、角速度 `0.05655 rad/s`。查询预算每物理步保持 4 次海浪、1 次风场。未触发 NaN/Inf、风速/帆力/速度/倾角诊断阈值；未出现 `Object went too far` 或视风力发散。Headless 日志没有出现先前的相机共线警告；由于没有渲染设备，摄像机画面稳定性仍须在图形运行中验收。

完整分钟采样和汇总见 [main_ten_minute.csv](/Users/smixu1/dev/boat-life-simulator/docs/sailing/c8_data/main_ten_minute.csv)。Godot Headless 进程退出时输出一条 Dummy renderer Shader RID 泄漏告警；它发生在测试退出阶段，未影响 600 秒刚体运行或产生帆船异常。

## 测试结果

通过：

- 平移不变性与 5 秒航行：通过，力臂范围检查 `3.3–3.7 m`；风向量相同；轨迹相符。
- Main AUTO + 正式风浪 600 秒：通过，逐步检查状态有限值、异常阈值和 `4 waves / 1 wind` 查询预算。
- 帆船空气动力：321 项通过。
- 帆船浮力：87 项通过。
- Main 场景接入：0 项失败，风场/WaveSampler 共享及查询数通过。
- 阻尼策略：17 项通过。
- `git diff --check`：通过。

以下既有按键输入断言仍失败，失败点与本次坐标改动无关：

- `test_sailboat_headsail.gd`：`J decrements the independent Jib target angle`。
- `test_sailboat_hydrodynamics.gd`：释放 A/D 后舵目标回中。
- `test_sailboat_auto_sail_trim.gd`：J/L 手动接管 AUTO。

三项测试构造 `InputEventKey.keycode`，当前项目 InputMap 对应操作使用 `physical_keycode`，直接调用 `_input()` 时事件不匹配。按本任务边界未改输入行为或这些无关测试。建议后续单独修正测试事件构造或明确键盘映射兼容策略。

## 修改文件与人工验收

- [sailboat_lab_body.gd](/Users/smixu1/dev/boat-life-simulator/scripts/sailboat_lab_body.gd)：新增局部点到世界质心力臂 helper，修正 Jib 视风，统一复核同类点速度计算，并公开只读 Jib 力臂诊断值。帆面积、压力中心、气动/水动力系数、重心、阻尼和风浪算法均未更改。
- [run_s1_c8_jib_world_space_fix.gd](/Users/smixu1/dev/boat-life-simulator/tests/run_s1_c8_jib_world_space_fix.gd)：平移测试与 Main 600 秒 Headless 回归。
- 本报告及 `docs/sailing/c8_data/` 中两份 CSV。

图形 Main 运行、Mac M2 Forward+、Windows Forward+、摄像机画面和船体视觉稳定性尚需人工验收。Headless 结果不能代替这些项目。
