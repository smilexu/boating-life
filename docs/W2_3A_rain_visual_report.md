# W2.3-A：真实天气驱动的降雨视觉系统

## 完成情况

已接入正式天气样本中的连续降水强度，并实现本地降雨视觉、动态海面雨滴细节、叠加式雨雾和独立调试面板。降雨视觉不会反向修改正式天气、风场、海浪位移、WaveSampler 或船舶物理。

## 修改文件

- `scenes/main.tscn`：接入客户端降雨控制器和调试面板。
- `scripts/rain_visual_controller.gd`：降雨粒子、风向倾斜、视觉参数平滑、质量档位和服务端跳过逻辑。
- `scripts/rain_visual_controller.gd.uid`：Godot 脚本资源 ID。
- `scripts/rain_visual_profile.gd`：将 mm/h 连续映射为纯视觉权重。
- `scripts/rain_visual_profile.gd.uid`：Godot 脚本资源 ID。
- `scripts/rain_visual_debug_panel.gd`：本地降雨调试 UI 与快捷键。
- `scripts/rain_visual_debug_panel.gd.uid`：Godot 脚本资源 ID。
- `scripts/weather_runtime/weather_runtime_godot_adapter.gd`：将正式天气样本中的降水强度与可用性传递给天气状态控制器。
- `scripts/weather_state_controller.gd`：保留正式降水只读状态并发出视觉目标信号；手动天气模式不凭天气预设推断降雨。
- `scripts/weather_controller.gd`：接收雨雾附加量，并将其合并进视觉基线。
- `scripts/day_night_visual_controller.gd`：由现有昼夜环境控制器统一合成雨雾与基础雾密度。
- `shaders/sea_water.gdshader`：增加近景程序化雨滴水面法线与粗糙度细节，不改变顶点位移。
- `scripts/boat_hud.gd`：增加降雨调试快捷键提示。
- `tests/test_rain_visuals.gd`：新增降雨映射、运行时隔离、快捷键、无头安全和海况参数兼容测试。
- `tests/test_rain_visuals.gd.uid`：Godot 测试脚本资源 ID。

## 数据流与雨量映射

`WeatherRuntimeAuthority` 的当前样本经 `WeatherRuntimeGodotAdapter` 传入 `WeatherStateController`。适配器只接受 `precipitation_intensity_mm_per_hour` 数值字段；字段缺失或不可用时保持 N/A，视觉按无雨回退，不从 Clear、Overcast 或降水概率推断实际降雨。

`RainVisualController` 通过 `precipitation_visual_target_changed` 获取正式目标，并按约 2 秒时间常数平滑到视觉雨量。`RainVisualProfile` 使用连续、单调映射：

```text
r = clamp(mm_per_hour / 14, 0, 1)
intensity = r ^ 0.52
streak_density = intensity ^ 0.70
sea_impact_density = intensity ^ 0.80
haze = 0.75 * clamp((intensity - 0.12) / 0.88, 0, 1) ^ 1.35
```

14 mm/h 以上视觉响应封顶；它只限制美术输出，不改动天气数据。该曲线较初版更早进入清晰雨幕；默认雨丝不透明度从 0.44 提至 0.55、长度从 0.55 m 提至 0.65 m，海面影响倍率从 0.8 提至 1.0。映射没有在雨量分级边界做跳变。音效强度只预留为只读输出，本阶段没有播放雨声。

## 雨丝

采用单个跟随当前摄像机的 `GPUParticles3D` 雨区。粒子使用世界坐标，发射器每 0.1 秒按 4 米网格跟随摄像机水平位置；已有雨丝不会随相机整体贴屏滑动，新雨粒子只在视野周边补充。雨滴方向按不超过 0.75 秒一次的 `WindField.get_wind_at()` 采样平滑更新。WindField 给出空气实际流动方向，雨丝使用该流向加向下重力，不把气象来向误当作雨滴运动方向。

雨丝是低饱和、非自发光的着色薄片，没有逐粒 GDScript 更新、碰撞节点或额外真实灯光。密度使用 12 档调节粒子 `amount`，不是逐帧重建粒子或节点。

## 海面雨滴细节与海浪兼容

`sea_water.gdshader` 在现有 Gerstner 顶点位移之后读取同一套 `world_coordinates` 和 `WaveTime`，按世界网格生成轻微扩散的环形水面细节。该效果只改变 `NORMAL` 与少量 `ROUGHNESS`，不写 `VERTEX`，不修改海浪相位、传播方向、波高、WaveSampler 查询、浮力或碰撞。没有为雨滴生成 CPU 节点，也没有对雨滴调用 WaveSampler。

效果距离限制在相机约 220 米内，并在 95–220 米间淡出以降低远处高频闪烁。雨滴环不是真实碰撞模拟，是程序化的视觉法线细节。

Low/Medium/High 使用不同的近景影响网格间距（2.0/1.4/1.0 米）和密度参数。自动化测试在 5、10、20、30 米极端海况预设下确认雨量 uniform 与极端海况参数可以共存，并确认雨量参数不会覆盖 F3 诊断模式或改变 WaveSampler 参数版本。该测试没有测量各海况下的实际渲染效果；陡峭波峰处的视觉贴合与滑动情况仍需 Forward+ 人工检查。

## 雨雾与环境合成

雨雾作为附加 `rain_haze_strength` 输入交给 `WeatherController`。`DayNightVisualController` 仍是 `WorldEnvironment` 雾参数的唯一写入者，在原有昼夜和天气雾密度上乘以受限的附加量。轻雨映射的雨雾为零或很弱；不会切换天气预设、制造雷暴或直接提亮夜空。没有引入另一套环境控制器。

## 调试面板

- 快捷键：`R`。核对了主场景脚本和 `project.godot` 输入映射，R 当前未绑定；普通 `F7` 仍保留给浅海床调试。
- 预设：无雨、毛毛雨、小雨、中雨、大雨、强降雨；也可以直接调 0–30 mm/h。
- 可调雨丝密度、长度、透明度、风倾斜、海面撞击强度、雨雾强度及 Low/Medium/High 质量。
- `使用正式天气雨量` 清除临时覆盖；关闭面板也会清除覆盖并平滑回到最新正式雨量。
- 覆盖只作用于客户端视觉，不写入天气系统或存档，不影响 F3 海况测试和 F12 风场覆盖。调试面板在 headless 与 dedicated-server 环境不启用；降雨 GPU 粒子也不会在那里创建。

## 质量档位与性能

| 档位 | GPU 粒子上限 | 雨滴细节网格间距 | 雨雾上限 |
|---|---:|---:|---:|
| Low | 1000 | 2.0 m | 0.45 |
| Medium | 2200 | 1.4 m | 0.60 |
| High | 3800 | 1.0 m | 0.75 |

此实现新增一个 GPU 粒子节点和海面片元着色器中的局部细节计算，没有每滴雨独立节点、物理碰撞或真实灯光。当前只完成代码与离线自动化检查，未在 Forward+ 运行画面中测量 FPS、CPU/GPU 帧时间、透明 overdraw 或 Draw Calls；因此不报告性能改善或帧率数字。雨滴细节在近景水面片元执行一次网格散列与环形计算，实际 GPU 成本需在目标 Mac 与 Windows 设备测量。

## 自动化验证

Godot 版本：4.7.2.stable.official.ed1daf0bf。

本轮实际执行的检查：

- `godot --headless --path . --script res://tests/test_rain_visuals.gd`：88 项通过，含更强雨量响应曲线的分级断言、非有限雨量值保持不可用、AUTO 恢复后重新接收正式雨量及 R 快捷键冲突检查。
- `godot --headless --path . --script res://tests/test_wind_field.gd`：23 项通过。
- `godot --headless --path . --script res://tests/test_wind_field_lab.gd`：30 项通过。
- `godot --headless --path . --script res://tests/test_wind_field_preset_ui.gd`：8 项通过。
- `godot --headless --path . --script res://tests/test_weather_wind_integration.gd`：50 项通过。
- `godot --headless --path . --script res://tests/test_weather_data_provider.gd`：69 项通过（离线模拟；预期的无效 JSON/网络错误用例打印了限流警告）。
- `godot --headless --path . --script res://tests/test_weather_stockholm_calendar_adapter.gd`：14 项通过。
- `godot --headless --path . --script res://tests/test_weather_simulation_core.gd`：71 项通过。
- `godot --headless --path . --script res://tests/test_weather_simulation_analysis.gd`：62 项通过。
- `godot --headless --path . --script res://tests/test_weather_simulation_lab.gd`：69 项通过，覆盖 1280×720、1632×957、1920×1080。
- `godot --headless --path . --script res://tests/test_weather_simulation_lab_cache.gd`：6 项通过，无 HTTP 请求。
- `godot --headless --path . --script res://tests/test_weather_runtime_integration.gd`：42 项通过。
- `godot --headless --path . --script res://tests/test_weather_runtime_persistence_rollover.gd`：93 项通过；10 个虚拟 Stockholm 日期边界耗时 7922.22 ms。
- `godot --headless --path . --script res://tests/test_world_time_manager.gd`：70 项通过。
- `godot --headless --path . --script res://tests/test_shallow_wave_constraint.gd`：80 项通过。
- `godot --headless --path . --editor --quit`：项目脚本/编辑器扫描退出码 0；headless 环境提示没有渲染设备，退出时报告一个 ObjectDB 对象泄漏，因此这不是着色器运行时编译或视觉通过证明。

以上各测试各自报告的检查数合计 775 项通过。天气预览的只读/不发网络请求隔离由 `test_weather_runtime_persistence_rollover.gd` 覆盖；该测试在 headless 中通过。WeatherDataProvider 用例中的网络错误是 fixture 模拟情形，不代表真实 API 测试。

## 仍需人工验收

尚未完成 Forward+ 肉眼验收和 GPU 性能测量。运行游戏后按 `R`，依次测试小雨、中雨、大雨，确认雨丝不贴屏、雨幕没有像雪、夜间不过亮、海面环纹不悬浮或穿透。再分别启用 F3 的 5/10/20/30 米极端海况，在静止和巡航视角观察近处波峰、波谷与远景水面；F3 和降雨面板可同时使用。最后在 Windows 与 macOS Forward+ 对比画面和帧时间。调试面板关闭后应恢复正式天气输入。

## 未实现内容

未实现雨声、雨滴真实碰撞、雪/冰雹、雷暴、海况自动增强或降雨对船舶物理的影响。当前没有专项低雨量粒子截图、雨雾浓度标定或目标设备性能数据；这些需要用户在可视运行环境中验收后再调。

---

# W2.3-A.1：降雨颗粒感与空间层次优化

以下记录覆盖本轮变更。上文的单层粒子与旧雨量曲线描述是 W2.3-A 基线。

## 原因检查与修改

基线只有一个世界空间 GPUParticles3D，发射范围约 84 × 36 × 84 m，雨丝 Quad 宽 0.014 m、默认长 0.65 m，材质受场景光照影响。粒子预算分布在大体积内，船外视角中近处雨丝覆盖率偏低。雨量曲线以 14 mm/h 封顶，强度再高也不继续增加输出。海面只有一层较大网格的扩散圆环；Medium 每个 1.4 m 单元最多扩至约 0.55 m，触发率偏高时呈现尺寸相近的完整环。雨雾最高权重 0.75，Medium 上限 0.60，容易比雨丝更先被注意到。

本轮将原预算拆成近、中两层，Medium 总上限仍为 2200：

| 质量 | 总预算 | 中景层 | 近景层 | 圆环单元 | 微撞击单元 | 雨雾上限 |
|---|---:|---:|---:|---:|---:|---:|
| Low | 1000 | 760 | 240 | 2.7 m | 0.62 m | 0.22 |
| Medium | 2200 | 1700 | 500 | 2.5 m | 0.42 m | 0.30 |
| High | 3800 | 2850 | 950 | 2.3 m | 0.30 m | 0.40 |

中景系统在较紧凑的世界空间体积中发射，寿命 2.0 秒；近景系统覆盖约 20 × 10 × 20 m，寿命 0.62 秒，雨丝略宽、略长，并独立按近景密度缩放。两个系统都使用世界坐标粒子，并按相机水平位置低频吸附跟随；不逐粒执行脚本、碰撞或风场查询。WindField 仍以 0.75 秒间隔采样一次，并平滑作用到两层。

## 连续雨量响应与水面细节

新的纯视觉映射以 22 mm/h 为归一化上限：

```text
n = clamp(mm/h / 22, 0, 1)
intensity = n ^ 0.30
mid_density = intensity ^ 0.70
near_density = intensity ^ 1.35
micro_density = intensity ^ 0.58
ring_probability = 0.18 × intensity ^ 1.8
haze = 0.42 × smoothstep-adjusted-intensity ^ 1.35
```

曲线连续。5 mm/h 仍保持可见，同时 22 mm/h 会显著增加近景层占比和不透明度，并达到最大密度。每个质量档位把原 GPU 粒子预算在两层之间分配，没有把总数翻倍。雨雾曲线和档位上限都下降，让雨丝与海面质感承担主要雨势表达。

`sea_water.gdshader` 现在在原 Gerstner 位移之后、同一 `world_coordinates` 上计算两类局部视觉细节：

- 密集微撞击：Medium 的单元间距 0.42 m，随机偏移、独立相位、约 0.18–0.29 秒生命周期；通过短促局部法线扰动、轻微粗糙度变化及低强度冷灰反照率变化表现。距离 22–44 m 渐隐。
- 稀疏圆环：随机半径为网格单元的 7.5%–16%，中心位置有抖动，Medium 最大尺度约 0.40 m；触发率按雨量升高但强降雨时也只有约 18% 基础概率。距离 28–78 m 渐隐。

两类细节仅影响 `NORMAL`、`ROUGHNESS` 和普通雨水渲染路径的轻微 `ALBEDO`；没有写 `VERTEX`、没有使用新的波浪公式、没有 CPU 波高查询或雨滴节点。水面仍读取现有波浪位移后的坐标和 `WaveTime`，不改变 WaveSampler、F3 参数、船舶浮力或波浪传播。

## 调试面板

保留 `R` 快捷键和现有雨量预设。面板仍是固定大小并可滚动，增加分组：

- 雨丝层次：中景雨幕密度、近景雨丝强度、长度、透明度、风倾斜。
- 海面雨滴细节：微小撞击密度、涟漪尺寸、圆环出现比例、海面细节强度。
- 远景空气：雨雾强度。

状态区显示近/中景密度、微撞击密度、圆环概率和当前粒子预算。所有控制仍只作用于本地渲染，不改正式天气。关闭面板仍清除雨量覆盖。

## 修改文件

- `scripts/rain_visual_controller.gd`：两层世界空间 GPU 雨丝、固定总预算拆分、雨量曲线参数接线和诊断数据。
- `scripts/rain_visual_profile.gd`：近景、中景、微撞击、圆环概率和雨雾的连续视觉映射。
- `scripts/rain_visual_debug_panel.gd`：新增分组与细节控制，保留 `R`。
- `shaders/sea_water.gdshader`：短寿命微撞击和稀疏小圆环，只改视觉着色输入。
- `tests/test_rain_visuals.gd`：雨量分层、预算不增长、质量参数、正式天气隔离及水面参数兼容断言。

## 检查结果与限制

本轮在 Godot 4.7.2 执行：

- `godot --headless --path . --script res://tests/test_rain_visuals.gd`：112 项通过。
- `godot --headless --path . --script res://tests/test_shallow_wave_constraint.gd`：80 项通过，覆盖 5/10/20/30 m 极端海况参数兼容。Headless 提示无渲染设备，并在退出时报告一个 DummyShader RID 泄漏；测试断言通过，但不代表实际 Shader 画面通过。
- `godot --headless --path . --editor --quit`：项目编辑器扫描退出码 0；没有渲染设备，退出时有一个 ObjectDB 清理警告。未完成 Forward+ 着色器编译视觉验证。
- `git diff --check`：通过。

本环境没有可用 Forward+ 渲染设备，因此没有真实测得 FPS、CPU/GPU 帧时间、Draw Calls、透明 overdraw，也没有观察 22 mm/h 的最终画面。新增一个 GPU 粒子系统，单帧多一次粒子绘制提交；总粒子数上限未增加。水面多了近景条件分支、散列和指数函数，实际 GPU 成本尚未测量，不能声称满足新增 GPU 时间低于 1 ms。

请在 macOS 和 Windows Forward+、相同相机与分辨率下使用 `R` 对比 5、10、22 mm/h，以及 F3 的 5/10/20/30 m 海况。重点确认近景雨丝是否自然、不贴镜头，微撞击是否足够细而不闪烁，少量小圆环是否仍可读，强降雨是否明显胜过中雨，夜间和海岸远景是否没有被雨雾洗灰。GPU 时间与帧率需在目标机器现场记录。

---

# W2.3-A.2：海面雨滴质感与降雨层次微调

## 审计结论

Medium 档微撞击网格间距为 0.42 m，5 mm/h 时微撞击密度约 0.77，22 mm/h 时达到 1.0；数量/采样密度不是主要短板。上一版微撞击的随机半径约为单元的 5.5%–9.5%，法线斜率系数为 `0.0012`，粗糙度增量最高 `0.10`，附加反照率只有约 1%–2%。这些变化叠加在动态海浪法线上后较弱，部分撞击点还会小于视口像素，导致海面大片区域仍显平滑、细节随视角变化闪烁。

圆环的 Medium 半径约为 0.19–0.40 m，触发概率在强雨时为 18%；相对微撞击偏大且比例偏高。雨雾则受 Medium `haze_cap=0.30` 限制，强雨时对基础雾密度的最大乘数为 `1 + 0.30 × 0.45 = 1.135`，所以远处海平线仍清晰。

## 修改

- 微撞击世界半径调整到单元的 7.5%–12%，Medium 约 0.032–0.050 m。根据 `fwidth` 测得的水平世界像素足迹有限扩展至单元的 18%，并用面积补偿限制其总能量，缓解近远视角变化时的亚像素闪烁。扩展与淡出仍仅在近中景工作，远处高频细节仍按原有 22–44 m 距离范围衰减。
- 微撞击法线斜率系数由 `0.0012` 提到 `0.0030`；局部粗糙度响应由 `0.10` 提到 `0.16`；仅在雨滴局部提高少量冷灰反照率。水面整体颜色没有被提亮。
- 圆环随机半径由单元的 7.5%–16% 缩至 5.5%–12%，法线斜率略降；圆环雨量系数从 `0.18` 降到 `0.14`。强雨时圆环仍多于中雨，但数量和尺度都给微撞击让出主次。
- 远景雨幕采用更陡的强度曲线 `0.62 × haze_input^2.2`，Medium 上限从 0.30 提到 0.52，High 上限提到 0.62，Low 仍限于 0.22。约 5 mm/h 的雨雾权重保持在 0.20 左右，与原先约 0.21 接近；22 mm/h 在 Medium 的有效上限为 0.52，配合环境合成系数 0.60，对基础雾密度的乘数最多约 1.312。仍由 `DayNightVisualController` 单点合成雾，没有新增全屏通道或体积雾，也未改变夜间雾色。
- 中景雨丝透明度和长度使用同一个连续权重：约 5 mm/h 时各降低约 5%，随着雨量上升平滑恢复；22 mm/h 时恢复为 100%。中景雨丝数量未减少，近景层未调整。
- 调试面板现有雨雾滑杆改名为“远景雨幕强度”，快捷键和覆盖行为保持原样。

没有增加 GPU 粒子、粒子预算、纹理采样、雨滴碰撞、WaveSampler 查询或节点。海面 Shader 只对现有雨滴细节增加两次屏幕导数计算（仅在雨效 uniforms 有效时），其余为局部着色数学。雨滴仍使用 Gerstner 位移后的 `world_coordinates`；只写法线、粗糙度和局部 `ALBEDO`，不写 `VERTEX`，不改 `WaveSampler`、波高、波频、陡峭度、浮力或船舶物理。5/10/20/30 m 的 F3 参数兼容断言仍在运行。

## 验证结果与限制

Godot 4.7.2：

- `godot --headless --path . --script res://tests/test_rain_visuals.gd`：139 项通过，包含雨量连续性、强雨/中雨层级、雨雾限制、粒子预算、视觉隔离、屏幕尺度过滤代码契约及波浪参数隔离。
- `godot --headless --path . --script res://tests/test_shallow_wave_constraint.gd`：80 项通过，覆盖 5/10/20/30 m 海况参数。该测试输出 `No rendering device on load` 和退出时一个 DummyShader RID 泄漏；数值断言通过，不代表渲染结果通过。
- `godot --headless --path . --editor --quit`：项目脚本类与资源扫描退出码 0。Headless 没有渲染设备，因此没有实际编译 Forward+ 着色器变体或完成肉眼验收。
- `git diff --check`：通过。

性能方面没有目标设备 GPU 数据可用，因此不报告 FPS、CPU/GPU 帧时间或“低于 1 ms”的结论。代码层面未增加粒子预算；雨量为零时新增导数分支会跳过。降雨时水面片元多计算屏幕足迹并执行既有微撞击场。该改动的真实成本需要在 Apple M2 与 Windows 独立显卡上测量。

人工验收仍需在 Forward+ 中用同一相机、分辨率和天气，对比无雨、5 mm/h、22 mm/h、22 mm/h + F3 10 m 海浪；另检查高/低视角、巡航、白天/夜间，以及 20/30 m 极端海况是否有严重闪烁或穿透。特别确认海面细碎撞击能看清、没有变成白色噪点，中雨仍自然，强雨远景更柔和但近景船体清楚。

## 2026-10-21 截图复查：水面撞击仍不可见

用户在 macOS Forward+ 的 22 mm/h Medium 画面中确认：雨丝可见，水面没有能辨认的撞击。复查发现，问题不在材质引用路径：`main.tscn` 中 RainVisualController、Ocean 及 WaveSampler 共用 `sea_water_material.tres`，Ocean 生成面也直接使用这份材质。主要短板是微撞击信号过弱：原法线扰动系数为 `0.0030`、反照率增量只有约 1.6%–2.4%；屏幕尺度扩张后还按面积比平方补偿，使斜视海面上的小撞击进一步变暗。

本次针对该反馈调整 `sea_water.gdshader`：

- Medium 撞击的程序化核心半径增至约 0.059–0.088 m，保留 0.42 m 世界单元；屏幕尺度扩张后的能量补偿设 0.78 下限，不再随面积比平方衰减。
- 撞击脉冲衰减放缓，增加短暂的小型涟漪边缘信号；法线斜率系数由 `0.0030` 调至 `0.0080`。近中景衰减从 22–44 m 延长为 35–75 m，避免俯视相机下大部分水面过早消失。
- 在撞击核心轻微压暗水色，并用低饱和蓝灰色表现涟漪边缘；边缘响应提升到约 7%–10% 线性反照率增量，同时微调粗糙度和局部高光。没有添加白色发光点、节点、碰撞或粒子预算。
- `RainVisualDebugPanel` 现在直接读取并显示海面 Shader 收到的微撞击密度、单元尺寸、撞击强度和圆环密度。强降雨 Medium 的预期实收值为 `1.00 / 0.42 m / 1.00 / 0.14`，便于区分输入断链和材质响应问题。

更新后运行：`godot --headless --path . --script res://tests/test_rain_visuals.gd`，146 项通过；`test_shallow_wave_constraint.gd` 的 80 项仍通过。Headless 无渲染设备，以上修改尚未经过修改后的 Forward+ 画面确认，实际撞击可见度以及 shader GPU 成本仍待玩家在同一场景复测。

## 2026-10-21 二次截图微调：减少完整圆环

后续 macOS 截图确认撞击可见了，但微涟漪过于完整且密集，水面看起来像铺满圆圈。本次把微涟漪改成：约 44% 的微撞击才显示边缘，其余主要显示小撞击核心；边缘只显示方向随机的弧段。弧半径与宽度分别缩至 `0.92–1.24 × sigma` 和 `0.32 × sigma`，并降低粗糙度、高光及蓝灰边缘强度；核心明暗保留少量差异。弧段方向由点积遮罩生成，没有加入逐像素角度三角函数。中近景 `35–75 m` 的衰减和 Medium `0.42 m` 单元保持不变。

当前代码目标是以细碎撞击核心为主、短弧涟漪为辅。该次微调后的 Forward+ 画面仍需玩家复测；不能依据 headless 测试声称已达到最终美术比例。

微调后再次运行雨效测试为 148 项通过，浅水/极端海况测试为 80 项通过，编辑器资源扫描与 `git diff --check` 退出码为 0。Headless 环境无渲染设备，未做修改后的肉眼验收或 GPU 耗时测量。
