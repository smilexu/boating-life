# Sunshine Clouds 2 评估

## 结论

Sunshine Clouds 2 已成为 Clear、PartlyCloudy、Overcast 三种天气唯一的云层实现。基础天空改用 Godot 原生 `ProceduralSkyMaterial`，不再使用旧手写云 Shader，也不保留旧方案的回退分支。安装前建立的 Git 检查点为 `6303a20`（`Checkpoint Sea Prototype before Sunshine Clouds 2 evaluation`）。

实际运行截图显示，晴天和少云有更饱满的积云顶部、柔和蓝灰色云底和较大的蓝天留白；阴天继续以高覆盖体积云形成连续云幕。效果资源仍用 Quarter 分辨率，采样步数没有增加。低角度船尾镜头下，远处积云仍会形成横向云带，但画面上方也能看到较高的云体。

## 版本与安装

- 插件：Sunshine Clouds 2，`plugin.cfg` 标记版本 2.7。
- 提交：[`a73a80b08fb37b255f8f10d49debd71e5541bd70`](https://github.com/Bonkahe/SunshineClouds2/commit/a73a80b08fb37b255f8f10d49debd71e5541bd70)。
- 上游：[README](https://github.com/Bonkahe/SunshineClouds2/blob/a73a80b08fb37b255f8f10d49debd71e5541bd70/README.md)、[MIT LICENSE](https://github.com/Bonkahe/SunshineClouds2/blob/a73a80b08fb37b255f8f10d49debd71e5541bd70/LICENSE)。README 声明 Godot 4.4+，并在 2.2 更新中列出 Apple Metal 支持。
- 项目仍使用 Godot 4.7.2 stable / Forward+，未升级引擎或更换渲染器。
- 插件文件与 MIT LICENSE 放在 `addons/SunshineClouds2/`，通过 Project Settings > Plugins 启用。只加入插件 addon 文件，没有复制其示例游戏。
- 主场景和测试场景使用官方 `SunshineCloudsDriverGD`、`SunshineCloudsGD`、WorldEnvironment Compositor 和 DirectionalLight3D 跟踪字段。插件 CompositorEffect 配置保存在 `resources/sunshine_clouds_preview.tres`。

## 当前参数

质量和噪声配置在 `resources/sunshine_clouds_preview.tres`；天气预设在 `resources/cloud_weather_profiles.tres`。

| 参数 | Clear | PartlyCloudy | Overcast |
|---|---:|---:|---:|
| 云量 | 0.54 | 0.64 | 0.91 |
| 云密度 | 0.95 | 0.95 | 0.78 |
| 光照密度 | 0.70 | 0.70 | 0.48 |
| 云色 | 暖白、柔和蓝灰 tint | 暖白、柔和蓝灰 tint | 灰蓝色 |

共用配置：云底/云顶 900/5,400 m；额外大尺度/大尺度/中尺度/小尺度噪声参数 285,000/80,000/19,000/6,500；curl 噪声强度 1,500（原为 2,800）；细节 0.36、锐度 0.58；最大步数 160、光照步数 12；渲染分辨率 Quarter；风向 `(1, 0, 0.35)`，四级风速 0.8/1.8/4/7。太阳方向由 WeatherController 设置的 DirectionalLight3D 传给插件驱动。此轮只改插件已有的数值配置和天气预设，没有改动噪声贴图、HeightGradient 或 Shader。

## 本轮积云微调

- 增加云层垂直范围，维持 900 m 的云底，把云顶从 4,800 m 提到 5,400 m，让云顶有更多向上展开空间，同时保留底部轮廓。
- 把四级噪声尺度分别调到 285,000 / 80,000 / 19,000 / 6,500，并把 `curl_noise_strength` 从 2,800 降到 1,500。插件仍用原 NoiseTextures；较弱的 curl 扰动减少了侵蚀边缘，较大的形状尺度让云团更饱满。
- Clear / PartlyCloudy 覆盖率从 0.57 / 0.68 微降到 0.54 / 0.64；晴天蓝天仍占主导，少云仍比晴天密集。略微提亮两种天气的环境 tint，保留温和的蓝灰云底。
- `max_step_count=160`、`max_lighting_steps=12`、Quarter 分辨率均未改变，没有增加 raymarch 采样成本。

## 实际验证

- Godot 4.7.2 stable（`ed1daf0bf`），Forward+，macOS 15.8.1，Apple M2 Pro，Metal 3.2。当前设备不是目标 M4，M4 性能未验证。
- 使用 `scenes/CloudComparison.tscn` 检查插件开/关和快速转动；使用 `scenes/main.tscn` 实际运行并按 1、2、3 查看三种天气。三种预设下船、海面、反光和信息 Panel 保持显示，云层按配置平滑改变。
- 比较场景 FPS HUD 使用 `Engine.get_frames_per_second()`。短时屏幕读数：插件关闭约 55–58 FPS，开启约 46–48 FPS（Quarter，1920×1080）。这不是长时间基准测试；完整帧时间分布和 M4 数据未测。当前实测场景在 30 FPS 基础目标之上，低于 60 FPS 理想目标。
- 短时快速转镜头未见明显闪烁、拖影或接缝。GUI 运行期间未见 Metal、Compute Shader 或 Compositor 错误。
- Headless Editor 扫描退出码 0；其日志说明没有 RenderingDevice，并在退出时报告一个 ObjectDB 泄漏警告，因此它只验证项目/脚本扫描，不作为 GPU 验证。macOS 还出现过 `IMKCFRunLoopWakeUpReliable` 输入法消息。
- 通过命令行中断测试进程时，Godot 退出日志报告插件的 RenderingDevice RIDs 未释放（pipeline、compute shader、texture 等）；正常关闭窗口的清理情况未单独验证。
- 本轮在主场景、1920×1080 窗口画面中检查 1/2/3 天气切换；等待过渡结束后，F3 实时面板读数约为 Clear 57 FPS / 16.67 ms、PartlyCloudy 57 FPS / 18.06 ms、Overcast 60 FPS / 16.67 ms。读数来自 `Engine.get_frames_per_second()` 和最近一帧的 `delta`，属于短时实机读数，不是长时间性能基准。设备仍是 M2 Pro，不是目标 M4。

## 运行方式

1. 在 Godot 中运行 `scenes/CloudComparison.tscn`。F2 切换比较场景的云层，F1 快速旋转镜头；左上角显示引擎 FPS。
2. 运行 `scenes/main.tscn`。按 1/2/3 切换 Clear、PartlyCloudy、Overcast。
3. 在 Inspector 编辑 `resources/cloud_weather_profiles.tres` 的天气参数，或编辑 `resources/sunshine_clouds_preview.tres` 的插件质量与噪声参数。

## 视觉差异与限制

- 相比旧云 Shader，插件表现出三维云体起伏、亮顶、内部阴影和云底层次；太阳受光方向跟随主场景 DirectionalLight3D。
- Quarter 重建带来轻度柔边。低角度船尾视图下，远处云团仍会横向排布成带；本轮提高了云顶，并让上方出现更高的云体，但还未彻底改变远景云场的横向透视分布。
- Overcast 现在也由插件绘制连续体积云幕；海面太阳高光仍可见，阴天环境下还可再减弱。
- Windows、M4、长时间云运动和正常 GUI 关闭后的插件资源清理尚未验证。
