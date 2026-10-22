# Nordic 28 V3.1：主帆微笑 Logo 可见性

## 根因

V3 的 SVG 源文件包含两只椭圆眼睛、弧形笑嘴和下方装饰弧线；但主帆 Shader 实际采样的 `sail_logo_smile.png` 与 SVG 不一致。检查原 PNG 的 Alpha 边界只有眼睛所在的窄水平带，在笑嘴与装饰弧线位置 Alpha 为 0，因此游戏里只能看到两个蓝点。Shader 的垂直 UV 翻转不是丢失曲线的原因。

已用透明 1024×1024 RGBA PNG 重建完整图案，并重新导入 Godot。当前 PNG 的眼睛、笑嘴和装饰弧线采样点都有不透明 Alpha；SVG 保留为可编辑源文件。主帆 Shader 继续按 Alpha 将深海军蓝图案直接混入帆布颜色，没有单独悬浮平面、文字、背景框、发光或阴影。Jib 的 Logo 开关仍为关闭。

## 新 Logo UV 布局

| 参数 | V3 | V3.1 |
|---|---:|---:|
| `logo_center` | `(0.50, 0.60)` | `(0.50, 0.58)` |
| `logo_size` | `(0.34, 0.085)` | `(0.98, 0.25)` |
| 采样矩形 U | `[0.33, 0.67]` | `[0.01, 0.99]` |
| 采样矩形 V | `[0.5575, 0.6425]` | `[0.455, 0.705]` |

新版完整纹理区域留在三角帆 UV `[0,1]` 内。修复后 PNG 的有效图案 Alpha 包围盒约为纹理 U `[0.235,0.766]`、纹理行坐标 `[0.235,0.863]`。Shader 保留 `1.0 - logo_uv.y` 的纵向翻转：它把纹理上方的眼睛放到帆的上方，并未造成遗漏。映射后的有效图案约落在帆 UV U `[0.240,0.760]`、V `[0.489,0.646]`，完整处于帆面内部，没有被帆边界裁切。有效图案两个 UV 方向的尺寸约为旧版的 2.9 倍。

Logo 附着在主帆原 UV 上，因此会随帆面 Shader 鼓风形变。Boom 旋转只改变帆的空间姿态，不改变 UV；在 0°、±30°、±60°下使用同一完整映射。`render_mode cull_disabled` 继续允许从帆的正反两面看到图案。

## 修改与验证

- 更新 `assets/boats/nordic28/sail_logo_smile.png`：补全两条曲线及 Alpha。
- 更新 `scripts/sail_triangle_visual.gd` 和 `shaders/sail_cloth.gdshader`：将 Logo 位置调整到主帆上中部并扩大采样区域。
- 扩展 `tests/test_nordic28_sail_visuals.gd`：检查 PNG 中眼睛/笑嘴/装饰弧线 Alpha、UV 范围、双面材质、Jib 不显示 Logo，以及 0°、±30°、±60°五种 Boom 角度下映射不越界。

检查结果：

- Nordic 28 V3 专项 Headless 检查：54 项通过。
- Godot 4.7.2 重新导入 PNG：完成。
- SailboatLab Metal 3.2 / Forward+ 启动烟测：运行 120 帧，退出码 0，无 Shader 或运行时错误。
- `git diff --check`：通过。

Forward+ 检查没有产出可供人工判读的游戏截图，因此第三人称实际观看距离下的最终视觉大小仍需人工验收；自动检查验证的是 Alpha 内容、UV 完整性和运行时渲染器加载。
