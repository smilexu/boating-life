# 第三方依赖记录

## Boujie Water Shader

- 来源：[Chrisknyfe/boujie_water_shader](https://github.com/Chrisknyfe/boujie_water_shader)
- 集成提交：[25f3c2da458e0a4f65bdb5903dc068b050930c06](https://github.com/Chrisknyfe/boujie_water_shader/commit/25f3c2da458e0a4f65bdb5903dc068b050930c06)（main 分支检出时的 HEAD）
- 许可：MIT，原始许可文件保留在 `addons/boujie_water_shader/LICENSE.md`。
- 兼容性：上游 README 声明 Godot 4.1+，并注明在 Godot 4.1.1 stable 上测试。本项目在 Apple Silicon macOS 的 Godot 4.7.2 stable 上完成了编辑器导入、主场景启动和 Forward+ 渲染检查；Windows 尚未验证。
- 安装方式：上游建议将 addon 放到 `res://addons/`，再从 prefab 开始使用。本项目保留 `addons/boujie_water_shader/` 插件文件并启用其 EditorPlugin，使用插件的 `Ocean` 网格、`CameraFollower3D` 和 `GerstnerWave` 资源；没有复制上游 `example/` 示例游戏。
- 本地调整：`shaders/sea_water.gdshader` 是上游 `water.gdshader` 的性能配置副本，关闭了折射、深度雾、泡沫、岸边泡沫及 Snell's window；上游插件文件未修改。
- 素材：`ocean_albedo_white_highcontrast.png` 随插件保留，受同一 MIT 许可声明约束。

## Sunshine Clouds 2

- 来源：[Bonkahe/SunshineClouds2](https://github.com/Bonkahe/SunshineClouds2)
- 集成提交：[a73a80b08fb37b255f8f10d49debd71e5541bd70](https://github.com/Bonkahe/SunshineClouds2/commit/a73a80b08fb37b255f8f10d49debd71e5541bd70)，插件标记版本 2.7。
- 许可：MIT；上游 `LICENSE` 保留在 `addons/SunshineClouds2/LICENSE`。
- 兼容性：上游说明面向 Godot 4.4+，2.2 起列出 Apple Metal 支持。项目当前使用 Godot 4.7.2 stable 与 Forward+；已在 macOS 15.8.1、Apple M2 Pro 的 Metal 3.2 上检查。Windows 和 M4 尚未验证。
- 安装方式：上游插件文件放在 `addons/SunshineClouds2/`，并在 Project Settings > Plugins 启用。项目保留驱动、CompositorEffect、NoiseTextures、编辑器 dock 与所需 Shader 文件；不复制插件的示例游戏。独立场景和主场景均使用官方 `SunshineCloudsDriverGD` 与 `SunshineCloudsGD` 类型，并由驱动跟踪场景的 DirectionalLight3D。
- 本地资源：`resources/sunshine_clouds_preview.tres` 是按上游公开的 `SunshineCloudsGD` 脚本字段建立并配置的 CompositorEffect；插件源码未修改。运行与性能记录见 [Sunshine Clouds 2 评估](SUNSHINE_CLOUDS_EVALUATION.md)。
