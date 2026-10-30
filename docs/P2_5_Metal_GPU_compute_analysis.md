# P2.5 — Metal GPU Compute 热点定位

## 结论

- 已读取正在运行的独立游戏 PID `9459`，父进程为 `zsh`；没有停止或重启游戏。Instruments 中的录制目标也是 `godot (9459)`。
- Frame 85 的三条 Compute 命令实际 GPU 执行时间合计约 **20.95 ms**，其中两条长命令为 **6.56 ms** 和 **13.74 ms**。这对 33.3 ms 的 30 FPS 帧预算是显著开销。
- 代码层面最吻合的来源是 Sunshine Clouds 的三个连续 Compute dispatch：深度预处理、云层 raymarch、后处理。该映射由帧内命令数量和源码 dispatch 顺序支持，但 Instruments 录制没有 GPU Shader Timeline，命令标签为空，因此仍是高置信推断，不是 GPU 工具直接给出的 shader 名称。
- 现有 0.67→0.50 FSR2 对照只显示平均帧时改善约 **1.09 ms**，P95 改善约 **0.74 ms**。用户随后提供了 F3 多项视觉诊断效果均关闭时的截图：约 **20.6 FPS / 48.50 ms 平均帧时 / 80.76 ms P95**。该截图与此前样本的视角和条件不完全一致，不能作严格因果对照；但它确认关掉这些视觉项后仍明显低于 30 FPS，P95 也仍约 80 ms。当前证据不支持继续把关闭 F3 视觉项当作主要解决方向，也不能区分 FSR2、Forward+ 内部 Compute 或其他 GPU/同步成本。
- 本轮没有修改代码、渲染配置或画质参数，也没有声称获得优化收益。下一步应检查**所有 F3 视觉项关闭时仍存在的工作**：在当前运行进程上重新录制开启 GPU Shader Timeline 的 Metal trace，识别剩余 Compute/Fragment/Vertex pass，而不是要求重复关闭已关闭的选项。

## 运行进程与 Instruments 证据

只读检查确认 `ps -p 9459` 返回 PID `9459`、PPID `3585`、命令 `godot`。Instruments 的 Run 1 元数据显示：Metal System Trace，目标 `godot (9459)`，arm64，MacBook Pro，macOS 15.8.1，20 秒（2026-10-29 17:40:25–17:40:45 CET）。GPU Counter Set 为 `Performance Limiters`；**GPU Shader Timeline: Disabled**。

Frame 85 的 GPU Channel Activity Summary：

| 命令 | GPU 通道执行时间 | CPU→GPU 延迟 | 备注 |
|---|---:|---:|---|
| Compute Command 9 | 0.647 ms | 4.46 ms | 短命令 |
| Compute Command 13 | 6.56 ms | 18.04 ms | 长命令 |
| Compute Command 16 | 13.74 ms | 30.20 ms | 最长命令 |

三条 Compute 的执行时间合计约 **20.95 ms**；CPU→GPU 延迟是队列等待/排队时间，不是 GPU 执行时间，也没有加进上面的合计。该帧的聚合 GPU 通道活动约 21.26 ms。整个 20 秒录制的 Compute 通道累计活动约 6.53 秒。通道活动可能并行，不能简单当作单一关键路径，也不能从累计值直接推出平均 FPS。

## 两条长 Compute 命令的来源判断

主游戏场景把 `resources/sunshine_clouds_preview.tres` 挂到 `WorldEnvironment` 的 Compositor；运行时资源默认启用 Sunshine Clouds。它的 `_render_callback()` 对每个 view 按顺序发出三次 compute dispatch。Frame 85 恰有三条 Compute 命令，顺序和数量与该回调相符：

| Instruments 命令 | 最可能的 Sunshine Clouds 阶段 | 依据与边界 |
|---|---|---|
| Command 9，0.647 ms | 深度预处理 | 回调第一条 dispatch 使用 `prepass_pipeline`；预处理 shader 对较低分辨率深度做覆盖采样。 |
| Command 13，6.56 ms | 云层主 raymarch | 第二条 dispatch 使用云 Compute pipeline；shader 对视线步进、噪声采样，并对云密度样本执行光照步进。 |
| Command 16，13.74 ms | 云层后处理 | 第三条 dispatch 使用 `postpass_pipeline`，处理云数据、采样深度并做大尺寸输出阶段的后处理。 |

命令 13、16 的阶段归属是按插件源码顺序推断的；GPU Shader Timeline 关闭且 Instruments 的 Label 列为 `-`，所以无法直接把命令名解析为 shader 名。它们**很可能**是 Sunshine Clouds 主 pass 和 postpass，但不能声称 Instruments 已直接证明该映射。

## 当前可见的 Compute 工作

- **Sunshine Clouds（项目插件）**：主场景每帧运行 compositor 回调；资源文件配置 `max_step_count=160`、`max_lighting_steps=12`、`resolution_scale=2`。QualityManager 会按画质档动态覆盖这些值，性能档对应 96/8 和 3，因此 Instruments 录制期间的实时数值无法仅凭 trace 确认。代码中主云 pass 的循环最多按 `stepCount` 进行射线步进，并在云样本中执行光照采样。
- **FSR2（Godot Forward+）**：项目的 3D 渲染比例诊断入口固定使用 FSR2，质量设置在低于原生分辨率时也选 FSR2。Godot 4.7 文档说明 FSR2 是 Forward+ 的分辨率重建方案，并通过 RenderingDevice 实现。当前 trace 没有标注可识别的 FSR2 命令，因此无法量出它在这两个长命令中的占比。
- **Forward+ 屏幕空间处理**：正式 Environment 启用了 SSAO、SSR 和 Glow。Godot 的 SSR 路径会生成 Hi-Z 深度；官方内部渲染说明指出该过程使用 compute shader。它们可能贡献其他 GPU 工作，但现有 Frame 85 的无标签记录不足以把某条长命令单独归给 SSR/SSAO。
- **海面**：`shaders/sea_water.gdshader` 是 `shader_type spatial`，不是自定义 compute shader。海面会消耗顶点/片元阶段，但没有证据表明它提交了这两条 Compute 命令。
- **编辑器云遮罩绘制 Compute**：`addons/SunshineClouds2/Dock/CloudsEditorController.gd` 也使用 Compute，但属于编辑器中的遮罩绘制工具，不是 Main 游戏常规渲染路径。

本次采样显示 Compute 的 GPU 实际执行占用显著，但同时也有 Vertex、Fragment 与 blit 活动；仅凭这份 GPU Counters 录制，不能把总帧时全部归到 Compute，也不能判断 CPU 提交是否同样限制帧率。延迟 18/30 ms 表明 GPU 队列存在排队，但该数值本身不能区分 CPU 提交慢、GPU 工作排队或其他同步原因。

## 已有 A/B 是否足够

P2.2 的同一 FSR2 模式渲染比例筛查：

| 设置 | 平均帧时 | P95 | 说明 |
|---|---:|---:|---|
| 0.67 FSR2 | 51.66 ms | 83.80 ms | 19.4 FPS |
| 0.50 FSR2 | 50.57 ms | 83.06 ms | 19.8 FPS |
| F3 多项视觉诊断效果关闭，67% FSR2 | 48.50 ms | 80.76 ms | 20.6 FPS；用户截图，视角/条件与基线不完全一致 |

0.67→0.50 的结果说明降低 3D 输入分辨率带来的收益很小，P95 基本不变；全关视觉诊断项的用户样本仍约 20.6 FPS，不能满足目标。由于镜头/采样条件未严格固定，不能把约 3 ms 的平均差值归因给某个效果。全关测试也不是单项归因实验；它足以说明这些可切换视觉项不是解决低帧率的充分手段，但不能量出任一项的独立贡献。以上结果不等价于在相同内部尺寸下比较 FSR2 与 FSR1/Bilinear。当前 F3 的分辨率选项会把 mode 固定回 FSR2，因此现有数据仍无法拆分剩余 Compute 成本。

## 优化与验证结果

- 本轮没有修改项目代码、物理、天气、海浪或画质默认值；没有重启游戏。
- 没有实施优化，因此没有优化后 FPS、平均帧时、P95 或画质对照，也没有声称性能提高。
- 未运行 Headless 渲染测试；它不能验证目标 Mac 上的 Metal GPU pass。

没有直接 shader 标签和单项 A/B 之前，调整云步数、云分辨率、FSR2 或 SSR 会改变画质/工作负载，无法证明改动针对了正确的 pass，因此本轮不做这些调整。

## 最小下一步采集（无需重启 PID 9459）

1. 保持当前 F3 多项视觉效果关闭、固定船位/镜头/天气和船舶状态；无需再重复全关测试。
2. 在 Instruments 选择仍运行的 PID `9459`，新录制 Metal System Trace 并启用 **GPU Shader Timeline**。记录 15–20 秒，重点检查关闭 F3 视觉项后仍存在的 Compute、Fragment、Vertex pass，以及 CPU/GPU 队列等待。当前 Run 1 的 Shader Timeline 关闭，无法直接命名 Compute 命令。
3. 如果新 trace 中长 Compute 消失而帧时仍高，重点转向 Fragment/Vertex、Godot 主线程渲染提交或同步等待；如果仍存在，按 shader/pipeline 标签确认它来自 FSR2、Forward+ 还是其他 pass。
4. 只有在这之后仍需要单独量化云层的独立贡献时，才做严格固定镜头的云层单项开/关对照。你已提供的全关结果不能分摊每个开关的贡献，但不需要再次重复全关流程。若要比较 FSR2 与 FSR1，则需另加诊断控件；当前 F3 不支持该选择，改代码后要由开发者手动重启游戏。

**当前判断：** GPU Compute 是重要的帧时贡献项；两条长命令最吻合 Sunshine Clouds 主 pass / postpass。尚未证明关闭或替换某项后能稳定越过 30 FPS，也没有依据在本轮改动正式渲染配置。拿到配对云层轨迹后，再决定是否针对具体 pass 做无明显画质损失的优化。

## 源码与文档

- 主场景 compositor 接线：[scenes/main.tscn](../scenes/main.tscn#L57)
- 云层 profile：[resources/sunshine_clouds_preview.tres](../resources/sunshine_clouds_preview.tres#L18)
- 三段 Compute dispatch：[addons/SunshineClouds2/SunshineClouds.gd](../addons/SunshineClouds2/SunshineClouds.gd#L787)
- 云 raymarch 与光照循环：[SunshineCloudsCompute.glsl](../addons/SunshineClouds2/SunshineCloudsCompute.glsl#L684)
- 云后处理：[SunshineCloudsPostCompute.comp](../addons/SunshineClouds2/SunshineCloudsPostCompute.comp#L263)
- 3D 比例强制选择 FSR2：[scripts/boat_hud.gd](../scripts/boat_hud.gd#L2420)
- 质量档对渲染比例/云步数的设置：[scripts/quality_manager.gd](../scripts/quality_manager.gd#L339)
- [Godot 4.7 分辨率缩放](https://docs.godotengine.org/en/4.7/tutorials/3d/resolution_scaling.html)
- [Godot 4.7 内部渲染架构](https://docs.godotengine.org/en/4.7/engine_details/architecture/internal_rendering_architecture.html)
