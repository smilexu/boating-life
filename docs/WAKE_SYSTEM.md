# GPU 粒子船舶尾流

正式尾流系统以 `GPUParticles3D + ParticleProcessMaterial + particle_wake_foam.gdshader` 为唯一维护方案。正式船与独立测试场景都实例化同一个 `WakeSystem.tscn`。

## 节点与坐标约定

- `BoatController` 的导航原点位于船体中心，船头沿局部 `-Z`，船尾沿局部 `+Z`；项目单位为米。
- `WakeSystem` 位于 `VisualRoot` 下，`WakeEmitter` 在局部 `Z=+2.75 m`。该位置对应当前约 5.3 m 长的帆船船尾。
- 尾流系统在高于 BoatController 的 process priority 读取船只世界坐标位移，并计算水平米/秒；不读取油门或自动驾驶目标速度。
- 粒子节点使用 `local_coords=false`。发射器跟随船尾移动与转向，已生成泡沫保留世界位置；粒子平面只采用船只水平航向，保持朝上，不跟随浮力俯仰 / 横摇而倾斜。
- 发射点每帧由 WaveSampler 查询一次当前海面高度；粒子 Shader 复用同一波浪资源、时间、强度与距离衰减参数，不对单个粒子做 CPU 波浪采样。
- 超过 `teleport_reset_distance_m` 的单帧位移会调用 `reset_wake()`，清掉旧粒子并重置速度基线，避免瞬移留下长直线。

## 配置资源

| 资源 | 用途 | 容量 | 可见速度 | 全效速度 | 视觉特征 |
| --- | --- | ---: | ---: | ---: | --- |
| `resources/wake_profiles/SailboatWake.tres` | 当前排水型帆船 | 240 | 0.45 m/s | 12 m/s | 较窄、柔和、密度低 |
| `resources/wake_profiles/FishingBoatWake.tres` | 未来小型渔船 / 工作艇 | 260 | 0.40 m/s | 10 m/s | 中等宽度与泡沫强度 |
| `resources/wake_profiles/SpeedboatWake.tres` | 未来高速快艇 | 300 | 0.55 m/s | 22 m/s | 较宽、较密、速度响应更强 |

每个 WakeProfile 可编辑粒子容量、速度响应、发射强度、发射宽度、粒子尺寸、扩散角、初速、寿命范围、泡沫透明度与颜色。寿命差异由 ParticleProcessMaterial 的 `lifetime_randomness` 给出；Godot 的寿命范围计算为基础寿命乘以 `[1-randomness, 1]`。[Godot 4.7 ParticleProcessMaterial 文档](https://docs.godotengine.org/en/4.7/classes/class_particleprocessmaterial.html)

快艇配置中的 `future_v_wave_strength` 仅是未来独立 V 形效果的预留值，目前没有任何 V 形波渲染。

## 不规则泡沫

- 发射盒横向宽度随平滑后的实测速度增大，粒子尺寸、扩散角、初速、透明度和发射比例也连续响应速度。
- GPUParticles3D 的世界坐标发射保留弯道轨迹；速度低于阈值时停止新发射，旧粒子按各自寿命淡出。
- 泡沫 Shader 仍使用两次轻量 value-noise 采样，但通过粒子随机旋转种子改变三种轮廓尺度、拉伸、侵蚀和泡沫阈值，颜色 / 透明度也做轻微随机变化。它不使用额外的高成本噪声层、折射或强 Bloom。
- 泡沫系统关闭后停止绘制和 CPU 处理；若在泡沫完全消散前重新启用，则保留尚存粒子。

## 添加船型

1. 复制一个 `resources/wake_profiles/*.tres` 并调整 WakeProfile 导出参数。
2. 在新船的 `VisualRoot` 下实例化 `scenes/WakeSystem.tscn`。
3. 调整 WakeSystem 场景中的 `WakeEmitter` 局部位置，使其落在新船船尾；确保船头约定与发射方向一致。
4. 在 WakeSystem Inspector 中指定新的 WakeProfile。

通过 `set_wake_profile(profile)` 可在运行时换型；`set_wake_enabled(bool)` 可平滑停发并让现有泡沫消散；`reset_wake()` 用于传送或重新定位后清除旧泡沫。

## 测试场景

`scenes/SimpleParticleWake.tscn` 复用正式 Boat、WakeSystem、海洋、天气、WaveSampler 和摄像机。

- F6 / F7 / F8 / F9：停船、2、7、12 m/s 测试速度。
- F10 / V：切换 S 弯。
- F11 / K：仅切换关闭 / GPU 粒子尾流。
- F12 / O：切换船尾跟随 / 倾斜俯视镜头。
- `--wake-integration-check`：自动使用实际 W/A/D、制动输入并运行 BoatController 自动驾驶逻辑，记录速度、发射比例和航迹状态。
- `--wake-benchmark-1920` / `--wake-benchmark-3440`：在当前画质与天气下对照关闭 / GPU 尾流。

## 限制

- 泡沫仍是平面粒子，海面位置由顶点 Shader 近似同步；船周围的遮挡、浪花受风影响和真实水流均未模拟。
- 活跃粒子数是容量乘发射比例的估算值，不做 GPU 回读。
- 体积云与分辨率仍是整体帧率的主要负载之一；当前没有可靠独立 GPU 时间监视器。
