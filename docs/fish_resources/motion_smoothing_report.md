# 鱼群游动平滑优化

## 原因

`FishSchoolRenderer._process()` 原先累积 0.16 秒后才调用 `_update_visible_fish()`，并直接写入 `MultiMesh.set_instance_transform()`；两个 AI 步进之间既没有更新实例变换，也没有视觉插值。鱼尾虽然在 `fish_swim.gdshader` 中连续摆动，身体位置和朝向仍然以约 6.25 Hz 阶梯移动。原实现因此把低频逻辑采样直接暴露成了可见运动。

在本轮水下观察中还发现鲱鱼朝向与运动方向相反。检查三个 GLB 后确认它们的局部头尾轴并不统一：眼部 UV 对应顶点位置分别显示针鱼眼部位于局部 +X（约 x=0.40）、三刺鱼位于 +X（约 x=0.37）、鲱鱼位于 -X（约 x=-0.39）；导入节点只绕 X 轴做 Z-up 到 Y-up 转换，未改变 X 轴方向。原渲染器把所有模型都按局部 +X 朝向速度，因此鲱鱼会倒游，尾部 Shader 也会朝错误一侧弯曲。

## 修改

- 保留 0.16 秒行为步进。速度、局部群游、分离/对齐/凝聚和惊扰逻辑仍只在该步进执行。
- 每条可见鱼在 AI 步进时保存前后 Transform 与 MultiMesh custom data；每帧在客户端渲染层插值，不修改 `FishSchoolState` 或权威资源快照。
- 位置使用线性插值；朝向从正交化后的 Basis 提取 Quaternion 并使用 `slerp`，缩放单独插值。插值权重限制在 0–1。
- 个体转向增加物种级角速度限制，避免 AI 方向突然变化；惊扰时允许较快转向。
- 每个 `FishSpeciesProfile` 明确配置 GLB 的头部轴和头部 X 坐标。针鱼、三刺鱼使用 +X，鲱鱼使用 -X；渲染器把各自的鼻端对齐实际速度方向。`fish_swim.gdshader` 根据头部轴计算尾部弯曲权重，避免鱼体波动朝头部传播。
- 每帧仍使用原有三组 MultiMesh，不增加逐鱼 Node3D。没有更换 MultiMesh 缓冲 API；本机测得的额外提交耗时较低，暂时保留易读、低风险的逐实例更新方式。
- F3 加入“鱼群逐帧平滑运动”A/B 开关，并显示 AI 频率、可见鱼数及 AI/MultiMesh 时间。
- 增加 `interpolate_authoritative_school_motion()`，供未来服务器适配器按权威时间戳在不规则消息间隔下插值；可选 `world_velocity` 只允许有限外推。此函数只生成客户端显示快照，不回写权威状态；当前本地模式还没有服务器消息流。

## 性能测试

测试机器：Apple M2 Pro，用户确认已连接电源；Godot 4.7.2 Forward+ / Metal；1920×1080 项目视口。固定主场景、水下 `FishObservationCamera`、天气和时间，冻结船只与本地权威管理器；在真实资源热点 `herring_v2_1_29` 附近测量。每项 1 秒预热、3 秒采样、3 次重复。VSync 关闭并设置 30/60/120 FPS 上限。场景 GPU 专用计时不可用，表中为整场景帧时间。

| 帧率上限 | 插值 | 平均 FPS | 平均帧时间 | P95 | P99 | 最差帧 | AI Tick 平均耗时 | MultiMesh 提交 |
|---:|:---:|---:|---:|---:|---:|---:|---:|---:|
| 30 | 关 | 30.06 | 33.265 ms | 34.027 ms | 34.266 ms | 34.385 ms | 10.616 ms | 0.351 ms / AI Tick |
| 30 | 开 | 30.02 | 33.314 ms | 33.836 ms | 34.486 ms | 34.764 ms | 9.616 ms | 0.526 ms / AI Tick；1.001 ms / 渲染帧 |
| 60 | 关 | 60.03 | 16.659 ms | 17.237 ms | 18.108 ms | 19.185 ms | 7.771 ms | 0.263 ms / AI Tick |
| 60 | 开 | 60.09 | 16.643 ms | 17.234 ms | 18.606 ms | 20.290 ms | 6.867 ms | 0.518 ms / AI Tick；0.841 ms / 渲染帧 |
| 120* | 关 | 60.01 | 16.665 ms | 21.474 ms | 24.267 ms | 26.397 ms | 7.922 ms | 0.301 ms / AI Tick |
| 120* | 开 | 60.03 | 16.657 ms | 20.934 ms | 24.138 ms | 25.105 ms | 8.332 ms | 0.646 ms / AI Tick；0.820 ms / 渲染帧 |

每次对照均为 221 条可见鱼、530,400 个鱼网格三角形、105 个 Draw Calls；插值开关没有改变鱼数、三角形或 Draw Calls。30/60 FPS 档的平均帧率保持在目标上限附近。`120*` 是请求的帧率上限，但实测约 60 FPS，说明当前运行视口/显示环境把帧率限制在约 60；这不是 120 FPS 验收。整场景帧时间包含云、海面等系统，不能单独归因鱼群或视为 GPU 计时。逐帧 Transform/custom-data 提交均值约 0.82–1.00 ms。

AI 更新本身在该热点约 6.9–10.6 ms；仍可能造成周期性帧时间尖峰。平滑解决的是运动可见的停顿，不消除 AI 逻辑峰值。若以后目标鱼数提高，应优先把 AI 更新切成时间预算队列，而不是提高 Tick 频率。

## 验证

- `godot --headless --path . --script res://tests/test_fish_resources.gd`：通过，`failures=0`。覆盖 6.25 Hz 设置、位置中点、±180° 短路径旋转、插值范围钳制、权威时间戳插值/受限外推、F3 A/B 开关、水层边界，以及三个物种的模型头轴映射。
- `godot --path . --script res://tools/benchmark_fish_motion_smoothing.gd`：完成水下观察视角 A/B。运行输出无着色器编译错误；退出时仍打印 RenderingDevice RID 泄漏警告。该警告在当前项目此前运行中也出现过，本轮不能确认其来源或归属。
- 朝向根因由 GLB 几何范围、贴图眼部 UV 对应顶点和导入节点变换确认；自动测试确认映射后的模型鼻轴与世界速度同向。没有录制视频，也没有独立的人工逐帧审片，因此运动连续性的最终主观观感仍待用户在游戏中确认。

## 修改文件

- `scripts/fish_school_renderer.gd`
- `scripts/fish_species_profile.gd`
- `resources/fish_species/herring.tres`
- `resources/fish_species/needlefish.tres`
- `resources/fish_species/three_spined_stickleback.tres`
- `shaders/fish_swim.gdshader`
- `scripts/boat_hud.gd`
- `tests/test_fish_resources.gd`
- `tools/benchmark_fish_motion_smoothing.gd`
- `docs/fish_resources/motion_smoothing_performance.txt`
- `docs/fish_resources/motion_smoothing_report.md`

