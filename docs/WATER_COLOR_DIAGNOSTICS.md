# 海水颜色斑驳诊断

## 对照截图

截图来自正式 `main.tscn`，使用同一船尾镜头、天气、船位和冻结的水面时间；图像为 1920×1080。A–D 使用调整前的水面参数，E 是本次结果。

| 模式 | 显示内容 | 截图 |
| --- | --- | --- |
| A | 固定基础水色，排除波面光照、颜色纹理和水深色调 | [A_flat_base.png](water_color_comparison/A_flat_base.png) |
| B | Gerstner 波浪光照与反射，不使用 albedo 颜色纹理和水深颜色 | [B_waves_no_color_texture_or_depth.png](water_color_comparison/B_waves_no_color_texture_or_depth.png) |
| C | B 加真实水深颜色 | [C_waves_plus_bathymetry.png](water_color_comparison/C_waves_plus_bathymetry.png) |
| D | 调整前完整 Shader | [D_full_shader.png](water_color_comparison/D_full_shader.png) |
| E | 当前完整 Shader，减弱波面着色法线和水深混合强度 | [E_final_reduced_normal_contrast.png](water_color_comparison/E_final_reduced_normal_contrast.png) |

诊断补图：[单独降低水深颜色权重](water_color_comparison/G_depth_strength_060_only.png)、[完整 Shader 使用恒定向上法线](water_color_comparison/P_full_flat_wave_normal.png)、[更平的备选参数](water_color_comparison/F_soft_normal_candidate.png)。

## 定位结果

- **主要来源是 Gerstner 法线参与光照后的明暗起伏。** B 已关闭水深颜色和 albedo 颜色纹理，仍能看到相同区域的明暗斑块；使用恒定向上法线后，起伏大幅减少。波浪位置和高度没有改变。
- Shader 没有直接用大尺度噪声乘海水 RGB。`water_detail_fbm()` 只用于生成细节法线；海水颜色纹理是高对比 albedo，但 B/D 的差异很小，不是大块斑驳的主要来源。
- **水深色调主要抬高近岸亮度，并叠加一部分空间色差。** C 比 B 更浅、更青；降低水深混合权重会压回一部分亮度。水深纹理的世界坐标映射和陆地/无效覆盖掩码没有发现异常；本次没有重建或修改原始水深数据。
- Fresnel、SSR、SSAO 和方向光阴影的隔离对照都未消除这类宽缓斑块。没有启用模拟海底阴影的着色功能；船影仍是单独的真实方向光投影。

同一张冻结截图中，对不含 HUD 的水面区域（像素 x=400–1799、y=550–1079）统计灰度亮度标准差：D 为 **13.48**，单独降低水深权重后的 G 为 **13.09**，当前 E 为 **8.39**。这只是画面区域对比度的诊断指标，不代表水深精度。E 比 D 低约 **38%**；更平的 F 为 7.78，但波面质感也略弱，因此默认保留 E。

## 本次调整

- `wave_normal_strength`：1.0 → **0.45**。只把用于着色的法线部分混向世界向上法线；不改变 Gerstner 顶点位移、WaveSampler、船体浮力或航行控制。
- `detail_normal_strength_near`：2.5 → **0.8**。降低近景细节法线造成的局部高光/明暗变化；远景淡出仍为 0。
- `depth_color_strength`：0.8 → **0.6**。真实水深仍提供连续的浅水青绿到深水蓝绿渐变，减轻近岸整体偏亮偏青的程度。
- 保留既有水深颜色、阈值、数据纹理、波高、波速、反射算法和泡沫设置。没有增加 Shader 采样或渲染层。

## 调试方法

运行正式场景后按 **F10** 逐项循环水面诊断模式：D 完整 → A 固定基础色 → B 无颜色纹理/水深 → C 加水深 → 法线 → Fresnel → 水深覆盖 → 漫反射 → 镜面反射 → 恒定法线对照。当前模式也会写入 Godot 输出。主场景恢复完整水面时选择 D（模式 0）。**B** 在完整模式下开关水深颜色。HUD 已提示 F10。

要重新生成受控截图和 120 帧对照数据：

```sh
godot --path . --script res://tools/capture_water_color_comparison.gd
```

脚本冻结水面时间，先以旧参数生成 A–D，再生成水深权重单变量图 G、当前设置 E 和更平的候选 F。报告写入 `report.json`。

## 运行与性能验证

- Godot **4.7.2 stable**，Forward+ / Metal 3.2，Apple **M2 Pro (Apple8)**，1920×1080。该测试设备不是 M4；本轮没有在 3440×1440 外接屏测量。
- 最近一次完整 Shader 对照：D **60.03 FPS / 16.66 ms**，水深权重单独降到 0.6 的 G **59.91 FPS / 16.69 ms**，当前 E **59.82 FPS / 16.72 ms**。波面和水深诊断模式 B/C 分别约 113/98 FPS；它们关闭了完整材质工作，不代表正常游戏性能。
- 测试使用 120 帧计时，`max_fps=0`、Godot VSync 模式为 0。多次运行的简单诊断模式帧率波动较大，完整 D/E 均约 60 FPS；法线/颜色调整没有可测的性能收益或损失。
- 截图脚本正常载入场景、读取 2052×2788 RG8 水深纹理并保存图像。退出时 Godot RenderingDevice 报告若干 RID 泄漏警告；它们发生在一次性 SceneTree 截图脚本结束阶段。没有观察到 Shader 编译错误。建议再从正常游戏启动入口检查一次交互画面。

## 文件

- Shader 与材质：`shaders/sea_water.gdshader`、`materials/sea_water_material.tres`
- 诊断热键和水深贴图状态：`scripts/bathymetry_manager.gd`
- HUD 提示：`scripts/boat_hud.gd`
- 可重复截图与计时：`tools/capture_water_color_comparison.gd`
- 截图和测试报告：`docs/water_color_comparison/`
