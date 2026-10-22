# Nordic 28 V3.2 驾驶舱舵轮

日期：2026-10-22  
范围：替换正常视图中的黄色舵角方块，增加共享的驾驶舱舵轮视觉。没有修改船舶物理。

## 黄色部件来源

黄色方块来自 `SailingBoat8m.tscn` 的 `VisualRoot/RudderAngleMarker/BladeDirection`。它是 C6.2 舵角诊断指示器，指示船尾方向，不是操舵机构，也不参与碰撞或施力。

它与水下 `VisualRoot/RudderPivot` 是两个独立节点。船体脚本把同一个 `actual_rudder_angle_rad` 分别赋给水下舵视觉枢轴和该诊断标记；水动力和目标舵控制本身不依赖黄色 Mesh。

本轮将 `RudderAngleMarker` 默认设为隐藏，并在 SailboatLab F3「水下结构检查」页增加“显示水面舵角方向调试标记”开关。调试标记仍读取原实际舵角，可随时恢复；水下舵叶、舵轴、RudderPivot 和舵力代码均保留。

## 新操舵台

操舵台通过 `VisualRoot/HelmVisual` 动态构建，挂在未缩放的 `VisualRoot` 下，不继承 GLB 的 `HullModelAdapter` 缩放。Main 与 SailboatLab 实例化同一个 `SailingBoat8m.tscn`，共用这套外观和尺寸配置。

| 项目 | 最终配置 |
|---|---:|
| 安装站位（VisualRoot 局部 X/Z） | `(0, +2.72) m` |
| 驾驶舱中心线地板采样高度 | `Y=0.69495 m` |
| 底座高度 | `0.72 m` |
| 底座下缘/上缘宽深 | `0.48×0.38 m` / `0.32×0.26 m` |
| 舵轮外径 | `0.706 m` |
| 舵轮辐条 | 6 根，批处理绘制 |
| 轮缘与辐条 | 暖棕色程序柚木纹，Metallic `0`、Roughness `0.38` |
| 轮毂、支撑柱 | 不锈钢色 PBR 材质 |
| 仪表台 | 深灰色简洁面板 |

底座 Y 由 Nordic 28 GLB 已变换三角面调用 `get_hull_surface_height_at(0, 2.72)` 得到，而不是沿用旧黄块位置或整个船体 AABB。测得地板 `Y=0.694952 m`；底座安装在此表面。整套部件跟随 V2.1 现有 `VisualRoot` 的 `-0.30 m` 装配偏移，因此没有再次叠加吃水偏移。

木纹由 256×256 可平铺程序纹理在初始化时生成一次，并作为普通 PBR `albedo_texture` 使用；纹理变化沿 Cylinder UV 的长度方向，轮缘的 UV 沿圆周方向映射。舵轮采用低面数环形网格、6 辐条 MultiMesh，以及独立的中心轮毂，没有增加刚体、碰撞体或逐帧纹理/Mesh 重建。

## 舵角映射

舵轮枢轴每个渲染帧直接读取船体的 `actual_rudder_angle_rad`，不读取输入键或目标舵角，也不维护第二份舵角状态。

```text
wheel_rotation_z = actual_rudder_angle_rad × (180 / 35) × -1
```

从船尾朝船首看，正实际舵角是右舷舵，舵轮按顺时针转动；负实际舵角则反向。映射结果为 `−35° → +180°`、`0° → 0°`、`+35° → −180°`。角度比例 `180/35` 和视觉方向符号存放于 Nordic 28 视觉 Profile。水下舵叶仍由原刚体脚本使用 ±35° 实际舵角驱动。

## 验证

- `godot --headless --path . --script res://tests/test_nordic28_helm_visual.gd`：33 项通过。覆盖地板采样、安装层级、底座/舵轮尺寸、柚木贴图与 PBR 参数、6 根辐条、调试标记开关，以及 `−35°/0°/+35°` 下轮舵同步。
- `godot --headless --path . --script res://tests/test_sailboat_lab_underwater_inspection.gd`：71 项通过，原有水下舵、舵轴、力点与摄像机检查保持通过。
- `godot --headless --path . --script res://tests/run_s1_c8_integration.gd`：Main 集成检查 0 项失败；确认 Main 使用共享帆船实体、风场/海浪连接和每步查询预算仍为 1 次 WindField、4 次 WaveSampler。进程退出时另有一条 `RendererDummy` shader RID allocation 消息，测试断言未失败。
- `git diff --check`：通过。
- 已通过 Godot 4.7.2 的 M2 Pro / Metal Forward+ 启动 SailboatLab；本轮没有取得可审核的运行时截图，因此底座与座椅、栏杆、绳索的最终像素级净空仍需开发者在 SailboatLab 与 Main 中人工观察。

没有新增物理采样、物理子步或水动力/空气动力参数。物理舵角、舵叶角度、船体质量、浮力、帆力和舵力计算保持原样。

## 修改文件

- `resources/sailing/nordic28_visual_rig_profile.gd`
- `resources/sailing/nordic28_visual_rig_profile.tres`
- `scenes/boats/SailingBoat8m.tscn`
- `scripts/nordic28_helm_visual.gd`
- `scripts/sailboat_lab_debug_panel.gd`
- `tests/test_nordic28_helm_visual.gd`
