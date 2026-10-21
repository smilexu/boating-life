# 浅水海浪振幅约束

本文说明开发测试模式中的水深驱动振幅约束，供后续维护和 Codex 会话定位当前实现。它记录当前代码行为和已验证范围，不代表真实浅水流体模拟或航行安全功能。

## 范围与代码入口

- `scripts/wave_sampler.gd`：参数、CPU 水面采样、理论波谷包络、诊断数据，以及向共享 ShaderMaterial 同步参数。
- `shaders/sea_water.gdshader`：顶点阶段读取水深纹理并缩放 Gerstner 波的 `Steepness`。
- `scripts/boat_hud.gd`：F3 极端海况区的浅水约束开关、参数滑块和实时状态。
- `scripts/bathymetry_manager.gd`：`sample_shader_depth_at_world_position()` 使用 CPU 预载的同一张 RG8 深度纹理，模拟 Shader 的 UV 映射和线性过滤，不进行 GPU 回读。
- `tests/test_shallow_wave_constraint.gd`：曲线、安全预算、纹理边界、参数同步和天气过渡的数值回归。

水深纹理格式、来源、坐标和数据限制另见 [`BATHYMETRY_DATA.md`](BATHYMETRY_DATA.md)。海底地形及其视觉偏移另见 [`SHALLOW_SEABED_SYSTEM.md`](SHALLOW_SEABED_SYSTEM.md)。

## 启用方式

浅水波浪约束只在 Debug 构建生效，`shallow_wave_constraint_enabled` 默认关闭。F3 选择 5 m、10 m、20 m 或 30 m 极端海况时会自动打开；切回正常天气时会关闭。F3 总开关可以临时覆盖当前状态。正式天气配置和正常天气波浪资源不被此功能改写。

约束只缩放主海面 `WaveCount` 波组的 Gerstner 位移与对应法线；不改变波长、频率、传播方向、相位或目标天气波高。Shader 和 CPU 端通过同一振幅倍率缩放每组波的 `Steepness`，而不是只提高或降低垂直位移。

## 水深来源与有效性

Shader 和 CPU 采样同一张 `bathymetry_depth_texture`：R 通道解码为 0–64 m 的 LAT 水深，G 通道表示有效水域覆盖。世界坐标使用 X 向东、-Z 向北，再映射到固定地理纹理范围；水面波动的 Y 坐标不改变海图水深。

两侧都使用 `valid_coverage_min` / `valid_coverage_max` 做 smoothstep 有效性淡化，并在纹理最外两格做边缘淡出。有效深度为：

```text
validity = smoothstep(valid_coverage_min, valid_coverage_max,
                      texture_coverage * edge_coverage)
effective_depth_m = decoded_LAT_depth_m * validity
```

陆地、NoData、纹理外部和边界不确定区域不会当作安全深水处理。有效性不足时 `effective_depth_m` 向 0 淡化，因而安全下探预算也连续趋近 0。CPU 通过 `BathymetryManager` 的本地 `Image` 线性采样来匹配 GPU 纹理过滤，不需要逐帧读取 GPU 纹理。

安全比例直接使用这份有效 LAT 深度，按需求计算 `effective_depth_m * (1 - safe_depth_ratio)`；这里不额外加上 `shallow_surface_above_lat_m` 的 0.5 m。该 LAT 偏移仍由既有海底/水面路径使用。以 5.52 m 为例，允许下探为 4.416 m，和测试算例一致。该余量是波面控制参数，不是船底到海床的真实间隙。

## 振幅算法

首先用当前波浪配置估算最大构造性波谷包络。它与 Shader 的 `P_DEG` 垂直位移和波组平均保持一致：

```text
max_possible_trough = sum(abs(wave.steepness * active_strength)) / active_wave_count
allowed_trough      = max(effective_depth_m * (1 - safe_depth_ratio), 0)
safety_scale        = clamp(allowed_trough / max(max_possible_trough, epsilon), 0, 1)
final_scale         = min(visual_zone_scale, safety_scale)
```

当波谷包络不超过 epsilon 时，安全倍率按 1 处理，避免除零；不存在可见波浪时不会因此增大波浪。有效深度不小于 0，最终倍率限制在 0–1，因此深水不会被百分比计算放大。

此前视觉曲线在 3 m 以下保持 0.07、到 8 m 平滑升至 0.35、15 m 为 0.70、30 m 为 1.0；安全余量使用固定 1.5 m。本次实现改为下表曲线和按水深百分比预留的预算：

| 有效水深 | 视觉振幅保留率 |
|---:|---:|
| 0 m | 0% |
| 3 m | 40% |
| 5 m | 60% |
| 10 m | 80% |
| 15 m | 90% |
| 20 m | 95% |
| 30 m 及以上 | 100% |

各相邻控制点之间使用 smoothstep 插值。普通天气的小浪保护沿用现有逻辑：波谷包络从 1 m 到 5 m 之间逐渐启用视觉分区衰减；包络不超过 1 m 时视觉倍率为 1。安全倍率独立计算，浅到不足以容纳小浪时仍会限制振幅。

## F3 参数

| 参数 / F3 项 | 默认值 | 范围 | 说明 |
|---|---:|---:|---|
| `shallow_wave_constraint_enabled` / 浅水约束 | 关闭 | 开 / 关 | 仅 Debug 生效；极端海况选择会自动开启 |
| `shallow_wave_safe_depth_ratio` / 波谷安全余量 | `0.20`（20%） | `0.10`–`0.50`，步长 0.01 | 水深中保留的比例；剩余比例是几何波谷预算 |
| `shallow_wave_full_depth_m` / 深水完整波浪阈值 | 30 m | 30–60 m，步长 1 m | 视觉曲线从 20 m 的 95% 平滑到此阈值的 100%；默认值对应上表 |
| `shallow_wave_min_amplitude_scale` / 3 m 水深振幅保留率 | `0.40` | 0–0.60，步长 0.01 | 0–3 m 曲线的 3 m 控制点；默认值对应上表 |

实时状态还显示当前局部水深及有效性、允许最大下探、视觉倍率、安全倍率、最终倍率、原始理论波谷和约束后的理论波谷。更改任一滑块后，CPU 参数和共享 ShaderMaterial 在同一调用中更新；“恢复浅水约束默认值”恢复 30 m、0.40、20% 参数。

若把完整波浪阈值调到 30 m 以上，20 m 到所选阈值之间会延长到达 100% 的平滑区间；此时 30 m 不再是 100%。要恢复文档中的默认曲线，使用恢复按钮。

## CPU / GPU 同步要点

1. 两侧读取相同纹理范围、方向、覆盖度阈值和过滤后的有效深度。
2. Shader 在未位移的世界顶点坐标 `wave_coords` 计算局部倍率；`WaveSampler` 先反解 Gerstner 水平位移，再在对应源坐标采样水深。
3. `WaveSampler` 由活动波组及活动强度计算 `shallow_wave_max_trough_excursion_m`，并同步到 Shader；安全比例和曲线参数也同步到同一材质。
4. CPU 和 Shader 镜像同一 smoothstep 控制点、低能量保护、百分比预算和 `min(视觉倍率, 安全倍率)`。CPU 用这个倍率计算船舶浮力查询到的水面；Shader 用它缩放主波组位移和法线。

CPU/GPU 公式和输入同步已由参数及数值测试覆盖，但 headless 测试环境没有渲染设备，未对 GPU 顶点高度进行直接回读比较。

## 数值检查与复现

在项目根目录运行：

```sh
godot --headless --path . --script res://tests/test_shallow_wave_constraint.gd
```

当前回归包含 80 项检查，覆盖默认曲线控制点、控制点连续性、5.52 m 算例、5/3/2/1/0.5 m 安全预算、10%/20%/30%/50% 比例、深水不放大、普通小浪保护、NoData/纹理边界、F3 同步，以及以下过渡：

- 正常天气 → 10 m
- 10 m → 20 m
- 20 m → 正常天气

10 m 极端海况的 5.52 m LAT 纹理样点结果：原始理论波谷 5.00 m，允许下探 4.417 m，视觉倍率 0.606，安全倍率 0.883，最终倍率 0.606，约束后理论波谷 3.03 m。0.001 m 有效水深时极端波浪倍率趋近 0；1 m 水深下 0.30 m 包络的小浪仍保持完整。

固定 1/60 s 的 CPU 过渡采样中，三种切换的最大单帧水面高度差分别为 0.022 m、0.013 m、0.060 m。该数值检查不代替实际游戏画面、GPU 顶点或船舶姿态验证。当前 30 m 左右的水深纹理栅格会平滑和近似近岸地形，headless 运行也不会提供 GPU 帧率数据。

## 限制

- 这是低成本视觉约束，不是浅水流体、折射、破碎或压力模拟。
- 约束不能替代海底碰撞或搁浅系统，也不保证吃水较大的船只不会触底。
- 水深纹理约 30 m 分辨率，真实底形、潮位、船体吃水和 LAT/游戏海平面误差可能造成残余穿底风险；安全余量比例不是导航安全值。
- 默认只在开发测试模式启用。把它变为正式天气系统默认行为前，需要在图形运行时验证深水/浅水画面、跨水深航行、船体浮力和目标设备性能。
- 没有增加水深纹理、网格、GPU 回读或真实浅水模拟。分段曲线比旧曲线多少量比较/插值运算，没有进行独立帧率基准。
