# Sea Prototype

这是休闲航海模拟游戏的 Sea Prototype，使用 Godot 4 和 GDScript。当前场景包含晴天天空、阳光、由 Gerstner 波驱动的动态海面，以及使用项目内 FBX 模型的第一艘可驾驶船只。

## 环境

- 推荐使用 Godot **4.7.2 stable 标准版**（非 .NET 版）。项目使用 Forward+ 渲染器。
- 可从 [Godot 官方下载归档](https://godotengine.org/download/archive/) 获取对应系统的编辑器。

## 打开与运行

1. 启动 Godot Project Manager，选择 **Import**，打开本目录中的 `project.godot`。
2. 打开项目后按 **F6** 运行主场景，或按 **F5** 运行项目。

也可在项目根目录通过命令行运行：

```sh
godot --path .
```

默认窗口为 1920×1080，窗口化且可调整大小。`scenes/main.tscn` 是主场景。

## 海浪调节

- `resources/sea_waves.tres` 保存四组 Gerstner 波的陡峭度、振幅、方向、频率、速度和相位。
- 在主场景选择 `WaveSampler`，可在 Inspector 调节 `wave_strength`（0–2）。它把同一组参数和 `WaveTime` 同时提供给海面 Shader 与 CPU 采样器。
- `Ocean` 使用插件生成的多级网格和远端海面；摄像机跟随节点按网格尺寸吸附移动，降低接缝和顶点游移。
- 海水插件材质暂时关闭折射、深度染色雾、泡沫、岸边泡沫和 Snell's window；远端地平线融合使用 WorldEnvironment 的深度大气雾。

## 天空与天气

- 按 `1` / `2` / `3` 平滑切换 `Clear`、`PartlyCloudy`、`Overcast`。预设参数集中在 `scripts/weather_controller.gd`，并统一驱动天空、方向光、环境雾、海水材质和 `WaveSampler` 的波浪强度。
- 左上角状态 Panel 常驻显示实际 FPS，约每 0.5 秒更新；启动数据尚稳定前显示 `FPS: --`。数值直接来自 `Engine.get_frames_per_second()`。
- 按 `F3` 打开天气与画面调试面板，可实时查看天气、太阳角度、云量、共享波浪强度、Draw Calls 和可见物体数；拖动滑杆可调整太阳高度、方位、云量和波浪强度。较矮的窗口中面板可滚动。
- F3 面板还可切换 `High` / `Medium` / `Low`、`30 FPS` / `60 FPS` / `Unlimited` 帧率上限以及窗口 / 全屏模式。设置保存在 `user://quality_settings.cfg`。新安装默认 High、60 FPS、窗口化。
- High 保持现有 4096 阴影图集、SSR/SSAO、四级海面网格和四分之一分辨率云计算；Medium 将阴影图集降至 2048、减少云步数并略减海面细节；Low 将阴影图集降至 1024、关闭 SSR/SSAO、降低云采样并使用三级海面网格。各档复用同一场景和材质。
- 30 FPS 档关闭 VSync，由 Godot 限帧；60 FPS 档启用 VSync 并设 60 上限；Unlimited 关闭 VSync 并取消引擎限帧。左上角显示的是实际 FPS，不是所选上限。
- 太阳高度以地平线上方角度表示（3°–75°）。方位以摄像机前向（世界 `-Z`）为 0°，顺时针增加；这是原型内的方向接口，不是地理罗盘方位。
- 天空由 Godot 原生 Sky Shader 生成，包含大气渐变、地平线薄雾、程序化层云与卷云。云层在半分辨率通道绘制；天空辐照贴图以实时 256×256 更新，让缓慢移动的云参与船体与水面的环境反射。
- Forward+ 使用 AGX 色调映射、PSSM2 方向光阴影、屏幕空间反射、轻量 SSAO、低强度 Glow 和深度大气雾；这些效果用于海水反射、船体层次与远端地平线融合。实际帧率请以目标设备运行时为准。
- 本轮画面检查与本机帧时间数据记录见 [`docs/WEATHER_VISUAL_CHECK.md`](docs/WEATHER_VISUAL_CHECK.md)。
- 本机质量档位与 FPS 基线记录见 [`docs/PERFORMANCE_REPORT.md`](docs/PERFORMANCE_REPORT.md)。本次测量设备为 Apple M2 Pro；M4 目标机仍需复测。

插件来源、提交、Godot 兼容性和许可记录见 [`docs/THIRD_PARTY.md`](docs/THIRD_PARTY.md)。

## 航行控制

- `W` 加速，`S` 减速，`A` / `D` 转向。
- `Space` 暂停或恢复船只运动；`T` 切换手动驾驶与自动巡航。
- 按住鼠标右键并拖动可环绕船只观察。
- HUD 内部以米/秒保存速度，同时显示换算后的节（knots）。自动巡航沿切换时的航向持续直线前进。
- `scenes/Boat.tscn` 是独立船只场景。船只原点位于静水面中心线，1 个 Godot 单位按 1 米处理，船首朝局部 `-Z`；`BoatController` 只控制 `MotionRoot` 的位置、航向和速度，`BoatBuoyancy` 只控制 `VisualRoot` 的高度、俯仰和横摇。
- `assets/boats/base_boat.fbx` 是项目内已有船模，直接作为场景实例使用；在 `Boat.tscn` 中以统一比例与水线位置做了变换，源模型未修改。
- `BoatBuoyancy` 默认用船体前左、前右、后左、后右四点采样海浪，并用阻尼弹簧平滑响应。可在 Inspector 调整浮动强度、俯仰/横摇限制、响应速度及采样点位置。
- 要查看采样点和对应水面高度，在 `PlayerBoat/MotionRoot/VisualRoot` 的 Inspector 打开 `debug_show_samples`。

## 目录

- `scenes/`：Godot 场景
- `scripts/`：GDScript 脚本
- `assets/`：美术与音频素材
- `docs/`：开发文档
