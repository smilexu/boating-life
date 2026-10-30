# P3 Graphics 设置

## 入口与操作

在航行中按 `Esc` → `设置` → `图形设置…`。选项先进入草稿，点击“应用”后生效；“取消”丢弃未应用的修改，“恢复默认”只载入默认草稿。显示模式或整体 Render Resolution 改动后会出现 15 秒保留提示；“保留”保存新配置，“恢复”或超时会还原之前的窗口、渲染和画质设置。

显示模式包括 Windowed、Borderless Window 和 Fullscreen；VSync 与 30 / 60 / Unlimited FPS 上限互相独立。Graphics Quality 包含 Performance、Balanced、High、Ultra 和 Custom。根 Viewport Render Resolution 单独提供 Native 100%、High 85%、Balanced 70%、Performance 55% 和 Ultra Performance 45%。

Advanced 默认折叠，包含 Additional 3D Scale、3D Upscaling Mode 和 FSR Sharpness。选择低于 Native 的根分辨率时，如果玩家没有在本次设置页手动指定额外 3D Scale，页面会将它设为 100%，避免意外双重缩放。玩家可以主动打开 Advanced 叠加缩放；页面会显示预计 3D 内部尺寸及双重缩放提示。Auto 在额外 3D Scale 小于 100% 时使用 FSR2，等于 100% 时使用 Bilinear。100% 下选择 FSR2 不会进一步降低像素数。

## 整体 Render Resolution 的实现

`QualityManager` 设置根 Window 的 `content_scale_mode` 为 `CONTENT_SCALE_MODE_VIEWPORT`，并根据当前窗口 client size 或当前显示器的像素尺寸，将 `content_scale_size` 设为相应宽高各自乘以所选比例后取偶数。Godot 将根 Viewport 内容渲染到该基准尺寸，再铺满窗口输出区域；这不是只改窗口大小，也不建立额外 SubViewport。宽高依据当前窗口/显示器，因此支持 16:9、16:10、21:9 等比例。使用 `CONTENT_SCALE_ASPECT_IGNORE` 消除黑边；目标尺寸来自同一输出区域比例，偶数取整只会产生很小的比例差。

Godot 文档区分了 `content_scale_size`（虚拟内容基准尺寸）和 `Window.size`（物理 client area 尺寸）；`CONTENT_SCALE_MODE_VIEWPORT` 会先按基准尺寸绘制再缩放到窗口。DisplayServer 的窗口尺寸和屏幕尺寸 API 均以像素为单位。[Window 4.7 文档](https://docs.godotengine.org/en/4.7/classes/class_window.html)、[DisplayServer 4.7 文档](https://docs.godotengine.org/en/4.7/classes/class_displayserver.html)

设置和 F3 性能面板分别显示输出窗口、屏幕、根 Viewport 当前尺寸、`content_scale_size` 请求尺寸及额外 3D Scale 后的内部尺寸估算。当前 Sunshine Clouds 插件取 `RenderSceneBuffersRD.get_internal_size()`；其主云计算使用按 `2^resolution_scale` 缩小的 dispatch，前/后处理仍按完整内部 3D 尺寸 dispatch。因此面板把云计算/后处理尺寸标为估算值，而不把它们误报为根 Viewport 输出尺寸。没有 GPU 捕获验证实际分配的纹理大小。

根 Viewport 缩放也会缩放 2D HUD 和菜单；该路径没有独立的原生分辨率 UI 合成层。窗口与根 Viewport 使用相同宽高比，布局和输入仍由 Godot 的 Viewport stretch/input 映射处理。高倍放大可能让文字和细线呈现像素感，需在实际画面中评估。

## QualityManager、预设与 F3

没有新增第二个画质管理器。ESC 菜单由现有 `GameMenu` 打开新的 `GraphicsSettingsPage`；所有已生效的画质、帧率、窗口、根渲染比例和额外 3D Scale 仍由场景中的 `QualityManager` 统一协调。

现有画质预设映射到项目实际参数：

| 预设 | 阴影图尺寸 / 距离 | SSR / SSAO | Sunshine Clouds（分辨率档 / 步数 / 光照步数） | 海面网格（分辨率 / LOD） | 植被密度 |
|---|---|---|---|---|---:|
| Performance | 1024 / 120 m | 关闭 / 关闭 | 3 / 96 / 8 | 8 / 3 | 0.65 |
| Balanced | 2048 / 200 m | 开启 / 开启 | 2 / 128 / 10 | 10 / 4 | 0.85 |
| High | 4096 / 260 m | 开启 / 开启 | 2 / 160 / 12 | 12 / 4 | 1.00 |
| Ultra | 4096 / 260 m | SSR 64 步 / SSAO 增强 | 2 / 192 / 16 | 14 / 4 | 1.15 |
| Custom | 保留用户逐项值 | 保留用户逐项值 | 保留用户逐项值 | 保留用户逐项值 | 保留用户逐项值 |

自定义页面可编辑阴影开关与距离、SSR、SSAO、云质量、海面网格质量和植被密度。只要玩家修改这些预设管理的视觉参数，预设显示为 Custom。窗口模式、VSync、FPS 上限、Render Resolution、3D Scale 与 upscaler 不会改画质预设。配置仍写入现有 `user://quality_settings.cfg`；旧版 High/Medium/Low 画质和 3D Scale 会迁移到新配置，旧版 3D Scale 保留以避免升级时改变原有渲染行为。存档、航行进度和天气配置使用独立数据，没有被改写。

F3 是临时诊断覆盖。打开时 `QualityManager` 保存当前正式设置；关闭 F3、退出 HUD 场景或点击“恢复玩家图形设置”时恢复该快照。F3 的画质、FPS、窗口、3D Scale、云可见性以及当前诊断建筑、海草、海面片元隔离状态不会保存进玩家 Graphics 配置。性能面板的 `Process monitor` 标注为 Godot Process 监控值，不称为 GDScript 总耗时。

## 多显示器与保存行为

切换 Fullscreen 只改变当前根 Window 的模式，不调用 `window_set_current_screen()` 强行指定显示器；Borderless 使用窗口当前所在显示器。窗口位置/尺寸按窗口化状态保存，退出全屏优先恢复原矩形。显示器匹配使用保存的屏幕尺寸、HiDPI scale 和桌面位置，显示器排列改变后尝试使用相同尺寸/scale 的当前或唯一匹配屏幕；找不到时回退到当前可用屏幕的可见区域。不会把 MacBook 内屏或固定索引写死。

Godot 4.7 的 DisplayServer 没有稳定的物理显示器 UUID/name 接口可供本实现使用。同型号、相同分辨率/scale 的多个显示器在布局已改变且程序重启后无法绝对区分；此时系统采用可见窗口屏幕/唯一签名或安全回退。仍需在目标 Mac 双屏上手工确认原生全屏 Space 的移动和恢复行为。

## 修改文件

- `scripts/quality_manager.gd` — 正式设置状态、旧配置迁移、视窗/画质应用、确认回滚、多屏状态和渲染尺寸诊断。
- `scripts/graphics_settings_page.gd` — ESC 设置中的 Graphics 页面草稿、Apply/Cancel/Defaults 与显示确认 UI。
- `scripts/game_menu.gd` — 从已有 Settings 页进入 Graphics 页面。
- `scripts/boat_hud.gd` — F3 渲染尺寸/云 Compositor 尺寸诊断、Process 指标说明及临时覆盖退出恢复。

本实现没有修改船舶物理、海浪采样、天气模拟、气动/水动力、正式云天气逻辑或系统显示分辨率，也没有关闭正式视觉效果。

## 验证与边界

已用 Godot 4.7.2 执行项目编辑器 headless 解析，以及主场景 headless 短时加载；脚本解析和资源/场景初始化未报告新错误。编辑器扫描仍打印了仓库中已有的 Polar 数据重复 UID 警告；主场景 headless 退出还报告一个 Dummy Renderer Shader RID 泄漏。

Headless 检查没有图形上下文，不能验证 Retina 真实渲染目标、Metal/FSR 画质、菜单字形清晰度、鼠标命中或 macOS 原生全屏切换。当前独立游戏进程没有被关闭或重启，因此它运行的旧内存版本不会自动加载本次代码；应用代码需在用户准备好时重新启动后才生效。建议届时在每块显示器分别验证：Windowed→Fullscreen→恢复、跨屏拖动后 Fullscreen、100/70/55% 根 Viewport 实际尺寸、鼠标交互，以及 16:9/16:10/21:9 的 HUD 和菜单布局。
