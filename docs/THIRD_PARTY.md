# 第三方依赖记录

## Boujie Water Shader

- 来源：[Chrisknyfe/boujie_water_shader](https://github.com/Chrisknyfe/boujie_water_shader)
- 集成提交：[25f3c2da458e0a4f65bdb5903dc068b050930c06](https://github.com/Chrisknyfe/boujie_water_shader/commit/25f3c2da458e0a4f65bdb5903dc068b050930c06)（main 分支检出时的 HEAD）
- 许可：MIT，原始许可文件保留在 `addons/boujie_water_shader/LICENSE.md`。
- 兼容性：上游 README 声明 Godot 4.1+，并注明在 Godot 4.1.1 stable 上测试。本项目在 Apple Silicon macOS 的 Godot 4.7.2 stable 上完成了编辑器导入、主场景启动和 Forward+ 渲染检查；Windows 尚未验证。
- 安装方式：上游建议将 addon 放到 `res://addons/`，再从 prefab 开始使用。本项目保留 `addons/boujie_water_shader/` 插件文件并启用其 EditorPlugin，使用插件的 `Ocean` 网格、`CameraFollower3D` 和 `GerstnerWave` 资源；没有复制上游 `example/` 示例游戏。
- 本地调整：`shaders/sea_water.gdshader` 是上游 `water.gdshader` 的性能配置副本，关闭了折射、深度雾、泡沫、岸边泡沫及 Snell's window；上游插件文件未修改。
- 素材：`ocean_albedo_white_highcontrast.png` 随插件保留，受同一 MIT 许可声明约束。
