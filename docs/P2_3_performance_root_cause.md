# P2.3 — Mac M2 Pro 固定帧耗时瓶颈定位

## 结论摘要

- 现有 30 秒样本显示：关闭视觉项、降低 Rendering Scale 后平均帧间隔有一定下降，但 P95 仍约 81–83 ms。它说明长帧尖峰仍存在，**不能单凭这些数据确定 CPU、GPU、渲染提交或同步等待中的根因**。
- 检查发现一个已确认的测试开关覆盖问题：`WeatherController._apply_current_state()` 会在天气状态应用时强制重新启用 Sunshine Clouds。已移除此写入，让云层渲染开关由画质设置保持控制；天气仍会更新云量、密度及海面天气参数。
- 当前环境只有 Godot 编辑器进程，没有运行中的 Main 游戏进程，无法取得目标运行时的 Profiler / Visual Profiler / Metal trace 数据。因此没有证据支持再做性能优化，也没有声称已改善 FPS。

## 用户提供的测量

| 条件 | FPS | 平均帧间隔 | P95 |
|---|---:|---:|---:|
| 原始效果，FSR2 67% | 19.4 | 51.66 ms | 83.80 ms |
| 视觉效果关闭，67% | 20.6 | 48.50 ms | 80.76 ms |
| 视觉效果关闭，50% | 22.8 | 43.84 ms | 82.56 ms |

这些测量来自用户在目标 Mac 上的截图；摄像机视角有差异，且一次同时关闭多个效果。不能据此将收益分配给某个特效。67% 到 50% 的两组视觉关闭数据平均帧间隔相差 4.66 ms，但 P95 反而高 1.80 ms；可见长尾帧耗时没有随平均值同步改善。

## 诊断开关与覆盖路径

| 项目 | 实际路径 | 检查结论 |
|---|---|---|
| 3D Rendering Scale | F3 的诊断选项直接设置根 Viewport 的 `scaling_3d_scale` 和 FSR2 模式，见 `scripts/boat_hud.gd`。 | 没有发现逐帧覆盖。用户手动改变“画质 / 3D 分辨率”时，`QualityManager.set_quality()` 会应用整套画质 Profile 并重置 scale；测试期间不要切换该档位。 |
| 云层渲染 | F3 调用 `QualityManager.set_clouds_enabled()`，设置 compositor resource 的 `enabled`。 | **发现并修复覆盖**：天气控制器之前每次 `_apply_current_state()` 都写 `enabled = true`。现在天气只改云的外观参数，不覆盖渲染开关。`SunshineCloudsDriver` 在云渲染关闭时仍推进云时间 / 位置，因此云层 A/B 只隔离 compositor 渲染效果，不是云模拟 CPU 成本。 |
| 海面片元隔离 | `BathymetryManager.set_fragment_cost_isolation()` 保存旧模式、设为模式 14，并在关闭时恢复；模式通过 Shader uniform 设置。 | 未发现逐帧重置。F10 会切换海水诊断模式，采样期间不要按 F10。隔离保留顶点波浪计算和渲染几何。 |
| 建筑 / 港口可见性 | HUD 缓存 Malmö 城区、Copenhagen Harbor 两个视觉根节点，并保存 / 恢复各 VisualInstance 状态。 | 只切换视觉实例可见性，不停用碰撞和逻辑。没有发现常规更新覆盖该开关。它不代表关闭所有海岸、桥梁或风电场。 |
| 海底植被 | `ShallowSeabedManager` 保存视觉开关，并应用于已生成及新建的植被节点。 | 生态和生成逻辑继续工作；没有发现可见性被逐帧覆盖。 |
| 帧率 / VSync | 当前 F3 用户截图显示 60 FPS 上限、VSync 开。`Unlimited` 会设置 `Engine.max_fps = 0` 并关闭 VSync。 | 60 FPS 上限本身低于目标性能不是限速原因，但 VSync 会影响 Present / 等待节奏，且 P95 接近刷新周期的倍数可能受其影响；这只是待测假设。Profiler 诊断时使用 Unlimited，保留一轮原 60 FPS/VSync 设置用于目标体验复测。 |

`TIME_PROCESS` 是 Godot 单帧处理监视器，不是 GDScript 独占时间，也不是 GPU 执行时间。需要用标准 Profiler 查看脚本 / 物理；用 Visual Profiler 看渲染 CPU 与 GPU 阶段。Godot 文档明确说明 Visual Profiler 不包含脚本和物理 CPU 时间。[Godot Debugger / Visual Profiler](https://docs.godotengine.org/en/4.7/tutorials/scripting/debug/debugger_panel.html)

## 已确认与未确认的瓶颈

**已确认：** 云层显示开关会被天气状态应用覆盖。此问题已修复，资源默认 `enabled = true`，新船局仍默认显示云层。未发现 3D scale 或植被可见性在常规帧更新中被覆盖。

**未确认：** 最昂贵的 GDScript 函数、波浪采样 / 船舶物理峰值、渲染提交时间、Metal GPU 时间、主线程等待以及额外 Viewport 成本。当前只有 F3 帧间隔、P95 与渲染计数，没有 Profiler 时间线；不能把 43–52 ms 的平均帧间隔或 80+ ms 的 P95 直接归因到 CPU 或 GPU。

## 修改与验证

- 修改 `scripts/weather_controller.gd`：移除 `_apply_current_state()` 对 `SunshineCloudsGD.enabled` 的强制写入。未改云层数据、天气模拟、海浪物理或画质默认值。
- `godot --headless --path . scenes/main.tscn --quit-after 2`：退出码 0，Main 场景和脚本加载；日志显示 `No rendering device on load`，退出时有 RendererDummy shader RID 泄漏提示。此检查只能证明资源 / 脚本可加载，不能验证 Forward+ 或 Metal 画面。
- `git diff --check`：通过。
- 无法提供修复前后 FPS，因为当前没有运行的 Main 进程，也没有目标渲染设备时间线。云层开关修复是否改变帧耗时必须在目标 Mac 上重新做单变量 A/B。

## 目标 Mac 最小 Profiler 采集

1. 在 Godot 编辑器按 F5 运行 Main，让游戏进程连接编辑器 Remote Debugger；保持双屏，游戏全屏放在内屏。固定船型、位置、船首向、镜头、天气和时间，FSR2 67%。测试 Profiler 时把 F3“帧率上限”选为 `Unlimited`（VSync 关闭），不要改变画质档；另行保留原 VSync 设置做一次体验复核。
2. 编辑器底部 `Debugger → Profiler` 点击 Start，稳定运行约 10–15 秒后 Stop。提供总览及按 Self Time 排序的 Script Functions 截图，并记录 Idle / Process / Physics、调用次数和峰值所在帧。该 Profiler 用来排序非渲染 CPU 工作，不代表 GPU 时间。[Godot Profiler](https://docs.godotengine.org/en/4.7/tutorials/scripting/debug/the_profiler.html)
3. 另开一次采样，在 `Debugger → Visual Profiler` 采集约 5–10 秒。提供某个典型帧及一次长帧的 CPU / GPU frame graph 截图。它分析渲染 CPU 与 GPU 阶段，不包含脚本 / 物理 CPU；不要与标准 Profiler 同时开启，以减少额外扰动。[Godot Visual Profiler](https://docs.godotengine.org/en/4.7/tutorials/scripting/debug/debugger_panel.html)
4. 如果 Godot 的 GPU 阶段数据不足，在 Xcode 的 Instruments 选择 `Game Performance` 模板，选中运行中的 Godot Main 游戏进程，录制 5–10 秒同一场景。观察 CPU 线程、Metal command submission、GPU busy / idle 与等待间隙。Apple 说明该模板结合线程与 Metal System Trace；Metal System Trace 显示 CPU / GPU 并行工作时间线。[Apple — Analyzing Metal app performance](https://developer.apple.com/documentation/xcode/analyzing-the-performance-of-your-metal-app)
5. 每次只开一个采集器；Profiler 捕获完成后在 F3 运行 60 秒帧样本复核，记录平均帧间隔与 P95。分析完把 F3 帧率选项恢复为测试前设置。

## 当前判断

本轮没有确认可优化的 CPU 或 GPU 热点，因此没有做猜测性性能修改。达到稳定 30 FPS 最值得的下一步，是拿到标准 Profiler + Visual Profiler / Metal System Trace 的同场景时间线，确认最大帧阶段后只优化该阶段，再用原双屏全屏场景复测。
