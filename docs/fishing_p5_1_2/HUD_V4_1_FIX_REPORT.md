# HUD V4.1 Fix Report

## 根因与修复

- **环境摘要拉伸：** 运行时面板只设置了位置和最小尺寸，没有按当前 Viewport 明确重设 Anchor 与四边 Offset；因此窗口布局变化时会继承过大的可用矩形。现在由 `BoatHUD._update_hud_layout()` 按窗口尺寸和 UI 缩放重设边界，并以内容最小高度决定面板高度。保留 FPS 行后默认约 300×114 px（1920×1080、UI 缩放 1.0）。详情窗口只在展开后出现。
- **海图判断更正：** 初轮把旧 `DepthChartHUD` 误当成重复地图删除。它实际是船周局部 Sea Chart；`FishResourceMap` 是资源/栖息地全区工具，二者功能不同。本次已恢复旧 Sea Chart，并让它负责左下默认视图；按 M 打开全区资源图时隐藏 Sea Chart，返回迷你模式时恢复。
- **右上天气诊断：** `WeatherRuntimeDiagnostics` 默认在 Debug 构建显示，并使用独立高层 CanvasLayer，所以会压住正式活动入口。正式 HUD 默认关闭这层诊断；天气运行时详情仍保留在 F3 面板中的 `WeatherRuntimeReadout`，底层诊断数据没有删除。
- **机动船仪表空洞：** 紧凑模式原先默认隐藏状态行，并给面板留了偏大的固定高度。现在默认显示真实驾驶模式与油门输入，自动巡航时显示控制器目标速度；紧凑尺寸约 310×116 px。展开信息只使用项目已有的前进/倒车速度上限配置，没有补造 RPM、燃油或档位。
- **FPS 显示：** 环境摘要保留一行轻量的实时 FPS 读数；它在预热 1.5 秒后每 0.5 秒刷新。F3 中仍保留更详细的性能诊断。
- **帆船仪表：** 与机动船保持同一右下区域规则，但紧凑高度按帆船信息量设为约 150 px；现有风、帆、自动操帆及航行细节仍由真实导航快照驱动。集成检查覆盖帆船仪表与海图的边界关系。

## 初轮实现记录（已由下方修正）

- 初轮只创建 `FishResourceMap` 并将其误设为左下缩略图；该判断已更正。
- `BoatHUD` 管理环境摘要、活动菜单、拖钓面板、航行仪表及鱼探仪入口。
- 天气诊断节点保留数据和诊断能力，默认不显示；详细运行状态通过 F3 面板查看。
- `FishResourceMap` 不因切船重复创建。

## 本地化

新增机动船自动巡航目标速度和展开速度限制的中英文翻译。现有活动入口、环境、导航、地图、拖钓和鱼探仪仍使用项目的 TranslationServer 与 CSV 翻译表。

## 修改文件

- HUD 与场景：`scripts/boat_hud.gd`、`scripts/compass_hud.gd`、`scripts/fish_resource_map.gd`、`scripts/weather_runtime/weather_runtime_diagnostics.gd`、`scenes/main.tscn`、`scripts/shallow_water_test_controller.gd`。
- Sea Chart：`scenes/DepthChartHUD.tscn`、`scripts/depth_chart_hud.gd`、`scripts/depth_chart_view.gd` 及其 UID 文件已恢复并优化。
- 翻译与测试：`resources/translations/fish_species.csv` 及生成的中英文翻译资源、`tests/run_s1_c8_integration.gd`、`tests/test_navigation_hud_format.gd`。

## 验证结果

| 检查 | 结果 |
|---|---|
| `godot --headless --path . --editor --quit` | PASS：场景导入与脚本解析完成。退出时有既存重复 Translation UID 警告及渲染资源清理警告。 |
| `godot --headless --path . --script tests/run_s1_c8_integration.gd` | PASS：HUD、地图快捷键、默认水深缩略图、窗口尺寸、拖钓/鱼探仪、语言切换和切船检查均通过，`0 failed`。退出时报告 1 个 DummyShader RID allocation leak。 |
| `godot --headless --path . --script tests/test_fishing_p5_1_2_hud.gd` | PASS：9 项检查，0 failures。 |
| `godot --headless --path . --script tests/test_navigation_hud_format.gd` | PASS：118 项检查。 |
| `godot --headless --path . --script tests/test_world_time_admin_controls.gd` | FPS/F3 检查 PASS；整套脚本 FAIL：3 项保存/重载断言因 `user://` 写入失败未通过，其余时间与 HUD 操作断言通过。 |
| `godot --headless --path . --script res://tests/test_fish_resources.gd` | 历史初轮结果：当时覆盖“迷你水深图”；本次扩展为验证局部 Sea Chart、M 展开资源图及纹理构建节流，见下方追加结果。 |
| `git diff --check` | PASS。 |
| Forward+ 视觉验收 / FPS A-B | **NOT RUN**：曾启动 Metal Forward+ 并加载主场景，但 CUA 返回 `cgWindowNotFound`，无法读取游戏窗口；未采集画面或 FPS 数据。因此不宣称实际 FPS 已恢复或给出数值增幅。 |

## 未完成项

需要在可操作的 Forward+ 窗口中确认环境摘要的实际留白、帆船/机动船观感、中英文文本裁切，以及海图/鱼探仪/展开工具之间的实际遮挡。Headless 布局断言通过不替代这项目视验收。

## 后续更正：恢复 Sea Chart 并审核采样（2026-10-31）

- 左下默认图恢复为船周局部 Sea Chart（海岸线、等深线、船位/航向和水深）；按 **M** 打开/收起全区鱼类资源图。资源图内的 `DepthQualityMapCanvas` 仅作为独立水深质量图层，不再冒充 Sea Chart。
- Sea Chart 原实现每绘完一行就执行一次整张 `ImageTexture.create_from_image()`，92 行会重复上传整张纹理。现改成 128×92 栅格分帧采样（每帧最多 256 像素），全部完成后只创建/上传一次纹理；每次重建用 3 次 WGS84 转换估算本地图幅的经纬度 Jacobian，代替每个栅格点都做 ECEF 逆转换；等深线和海岸线投影缓存到图幅中心变化时更新。静止且航向不变时停止周期性重画，隐藏期间不启动或重启栅格构建。
- Headless 主场景数据样本：11,776 个栅格点中 6,902 个执行 DTM 深度采样（其余为陆地/无覆盖）；单帧采样预算 256，连续构建观测最大 slice 2.25 ms，完成后纹理创建计数为 1。每个有效插值点读取 4 个 DTM 栅格单元（约 27,608 个源单元读取/次建图），每次构建只做 3 次完整 WGS84 转换。此值是本次 headless 构建观察，不是 Forward+ FPS 或 GPU 性能数据。
- Fish Finder 扫描仍为 3 Hz、180 列/60 秒历史。真实 Authority 共 1,510 个学校；扫描按最大声锥水平脚印加学校代理半径查询，并保留至少 16 m 的近场诊断范围，而非查询整个 220 m 斜距球体。10° 半锥、45 m 最大深度时锥底半径约 7.93 m，默认候选查询半径因此约 16 m。24×24 网格中的 224 个有效水域点，候选总数从旧半径的 29 降至 1；25 个采样点减少候选数。1510 个学校锚点上旧/新累计候选均为 1806，平均 1.20、最大 3，说明当前学校中心周围本来很稀疏，但任意船位样本可避免扫入远离声束的学校。
- 在候选最密的一处真实学校区域，对同一场景连续强制扫描 30 次：每次考虑 3 个学校、最多 3 条回波，平均 0.396 ms、P95 0.411 ms、最大 0.468 ms。该位置每次最多约 8 次环境 API 查询（探头底部/水面各 1 次，3 个学校各 1 次海底和水面采样）及 15 个固定垂直重叠计算；3 Hz 对应最多约 24 次环境查询和 45 个垂直采样计算/秒。headless 数据显示传感器负担较小，保留频率以维持 60 秒滚动画面分辨率。该同步计时不代表渲染态整帧耗时，也未测 Forward+ FPS。
- 目前没有证据要求再降低传感器频率或减少 180 列历史。若后续 UI 隐藏后无须维护连续 sonar history，可另行考虑按工具启用扫描；本轮维持现有实时数据契约。
- `fish.map.mini_title` 标识 M 对应全区资源图；开发地理覆盖仍为 **Shift+M**。Forward+ 视觉/FPS A-B **NOT RUN**，headless 数据不冒充真实画面性能结论。

### 本次定向验证

| 命令 | 结果 |
|---|---|
| `godot --headless --path . --script res://tests/test_fishing_p4_1.gd` | PASS：`failures=0`；包含窄候选查询、声束外诊断、真实/活动船切换、3 Hz 和有界历史。 |
| `godot --headless --path . --script res://tests/test_fishing_p4_2.gd` | PASS：`failures=0`；显示深度/历史滚动、预览隔离与 Fish Finder UI。 |
| `godot --headless --path . --script res://tests/test_fish_resources.gd` | PASS：`failures=0`；默认 Sea Chart、每帧采样上限、纹理单次上传、隐藏期间不采样、M 切换与资源图。 |
| `godot --headless --path . --script res://tests/run_s1_c8_integration.gd` | PASS：`0 failed`；含 Sea Chart 默认可见、海图切换、本地化、窗口边界和切船检查。 |
| 临时数据审核 `godot --headless --path . --script /private/tmp/sonar_audit.gd` | 完成：1510 所学校锚点、224 个有效海水网格点、30 次同场景扫描与 Sea Chart 栅格构建统计；数值见上。退出仍报告一个 DummyShader RID 清理警告。 |
| `godot --headless --path . --editor --quit` | PASS：场景导入与脚本注册；保留仓库已有的两个重复 translation UID 警告和一个 ObjectDB 清理警告。 |
| `git diff --check` | PASS：无空白错误。 |

Headless 无真实渲染设备；虽曾启动 Metal Forward+ 主场景，但窗口无法被 CUA 获取，Sea Chart 的画面验收及 FPS 前后对比仍为 **NOT RUN**。不能据此宣称某个 FPS 提升数值。

### Sea Chart 内框线条裁切（2026-10-31）

- 用户截图确认，海岸线/等深线会越出地图绘图区，进入标题及下方留白。根因是投影折线只受整个 `DepthChartView` 控件的 `clip_contents` 限制，没有按内部 `_map_rect` 裁切。
- 现在投影缓存时将海岸线和等深线逐段裁至地图内框；折线离开地图后会分段，避免把框外路径错误连起来。底图、真实坐标、深度数据和扫描没有变化。
- `test_fish_resources.gd` 增加跨框裁切、框外绕行分段以及实际缓存点边界断言；测试通过。Forward+ 截图复验仍为 **NOT RUN**。
