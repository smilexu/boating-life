# S1-C8-UI：Main 航行 HUD 缩放与易读性

## 结果

Main 的航行 HUD 现已支持统一 UI 缩放和简洁/详细两种信息层级。帆船模式的右下角面板以中文突出航速、船首航向、真实风速、风从何处来、相对视风方向和操帆模式；详细航行数据和帆船物理诊断分开放置。动力艇继续使用原有 HUD。

设置入口：按 **ESC → 设置**，选择“界面大小”和“航行信息”。默认界面大小为 **大 · 125%**，信息模式为“简洁”。修改后立即生效并保存。

## 缩放审计

- 主窗口的基准设计尺寸为 1920×1080。修改前项目没有显式启用 HiDPI，也没有统一的玩家 UI Scale；航行 HUD 中的字号和面板尺寸主要是固定逻辑坐标，因此 Mac Retina 上显示偏小的原因与这两个实现缺口相符。
- 现在显式启用 Godot HiDPI，并使用 `canvas_items` stretch 与 `expand` aspect。用户 UI Scale 通过根 Window 的 `content_scale_factor` 应用，五个档位为 90%、100%、125%、150%、175%。
- UI Scale 只控制 Canvas UI。不会设置 `Viewport.scaling_3d_scale`，也不会更改相机、世界比例或 3D 分辨率。集成检查会比较设置前后的 3D scale。
- 界面大小与简洁/详细选项保存在现有 `user://quality_settings.cfg` 的 `[interface]` 区段；没有覆盖音乐设置 `user://settings.cfg`。
- F3 性能诊断显示 OS、窗口模式、Godot Window/Screen API 尺寸、HiDPI 开关、DisplayServer 屏幕比例、UI Scale、Window 内容比例、stretch 模式、根 Viewport 和 3D 内部渲染估值。Godot/DisplayServer 返回的 screen scale 是 API 值，不能直接称作操作系统真实 DPI。

Mac 偏小的确切系统层原因尚未由同一台机器上的 Retina 截图和系统缩放对照确认。已确认的代码因素是此前缺少显式 HiDPI 开关和玩家可调的统一 UI Scale；本轮不把这等同于已测得的物理 DPI 根因。

## Main 航行 HUD

右下角帆船面板保留既有俯视风向/船体示意图和操作控件，核心数据分层如下：

- 最大字号：航速（节）和船首航向。
- 次级：真实风速、真实风向来向、相对视风来向。
- 状态：AUTO/手动、现有 AutoSailTrim 的 NO-GO 状态、主帆/前帆/舵角。
- 详细模式：SOG、COG、HDG、TWS/TWA、AWS/AWA、目标与实际帆角、舵角、横倾和侧滑。
- 前帆开关标为“测试开关”，关闭时显示“已关闭”，不宣称实现了卷帆。
- A/D、Z/X、J/L、T 操作提示从当前 InputMap 读取；帆船控制也使用对应 InputMap action。

简洁模式不展示专业角度缩写堆叠。详细模式保留中文说明并以英文缩写辅助识别。迎风低效提示直接读取现有 AUTO 控制器 `no_go` 标志，没有另造阈值或修改物理。

航行示意图沿用与航行 HUD 相同的导航快照。真风向文字用世界风来向（0°北、90°东、180°南、270°西）表达；相对来风侧采用项目已有符号语义（负角左舷、正角右舷）。静风时显示无稳定风向/静风。详细模式中的无效 COG 显示为“—（方向不可靠）”。

主航行面板仍与海图分居屏幕右下和左下。F3 物理数据移入独立的“帆船物理”Tab，天气/画面诊断留在原 Tab；打开 F3 时隐藏普通帆船操作面板，减少遮挡。小窗口下控件容器可滚动。

## 术语

| 缩写 | 中文名称 | UI 含义 |
|---|---|---|
| SOG | 对地航速 | 本项目主标签显示为“航速”，单位节（kn） |
| HDG | 船首航向 | 船头指向 |
| COG | 实际航迹方向 | 船的水平实际移动方向；低速无效时显示横线 |
| TWS | 真实风速 | 天气风场中的风速 |
| TWD | 真实风向 | 风从哪个世界方位吹来 |
| TWA | 相对真风角 | 真实风来向相对船首的角度 |
| AWS | 视风风速 | 船运动后实际感受到的相对风速 |
| AWA | 相对视风角 | 视风来向相对船首的角度 |
| MAIN | 主帆 | 桅杆后方主帆的实际角度 |
| JIB | 前帆 | 桅杆前方前帆的实际角度 |
| AUTO | 自动操帆 | 自动调整帆角，不负责掌舵 |
| NO-GO | 迎风低效区 | 复用现有自动操帆判定 |

## 布局验证

布局检查覆盖 1280×720、1600×900、1920×1080、2560×1440，以及五个 UI Scale，共 20 种逻辑尺寸组合。自动检查确认右下角面板没有越过屏幕边界，并与左下角海图预留区分开。设置菜单和右下角帆船面板会根据可用高度调整并使用滚动容器。

这些是 Godot 逻辑坐标/布局几何检查，不是四种真实显示器截图。当前未在实际 Mac Retina 窗口/全屏及 Windows 100%、125%、150% OS 缩放环境逐项验收。尤其需要人工观察字体视觉尺寸、点按面积和 F3/海图遮挡。

## 修改文件

- `project.godot`：HiDPI、CanvasItem stretch、帆船操控 InputMap。
- `scripts/quality_manager.gd`：UI Scale、设置持久化和 F3 显示诊断。
- `scripts/game_menu.gd`、`scenes/main.tscn`：ESC 设置入口与响应式设置面板。
- `scripts/boat_hud.gd`：简洁/详细航行面板、键位提示、F3 船物理 Tab 与布局适配。
- `scripts/navigation_hud_format.gd`：风向中文描述、相对来风方位、InputMap 键位格式化。
- `scripts/sailboat_navigation_instrument.gd`：Main 合并式仪表的图形与文字分工。
- `scripts/vessel_preview_card.gd`：修正预览相机尚未入树时的朝向设置，清除 Main Headless 集成中的两条 `look_at` 错误日志。
- `scripts/sailboat_lab_body.gd`：帆船键盘控制读取同一 InputMap action。
- `tests/test_navigation_hud_format.gd`、`tests/run_s1_c8_integration.gd`：显示语义、键位、缩放和 Main 切船回归。

## 检查与限制

Headless 自动检查验证格式化语义、四种逻辑分辨率下的布局几何、面板与海图边界、帆船/动力艇 HUD 切换、导航简洁/详细模式、InputMap 提示、UI Scale 即时生效且不改变 3D scale，以及帆船仍是每个物理步一次 WindField 和四次 WaveSampler 查询。格式化/布局测试通过 78 项；Main 集成测试 0 项失败。它不能替代 Retina/Windows 原生窗口的图形人工验收，也不能证明 GPU 帧率或 Mac M2 Forward+ 性能。

Main Headless 集成运行时曾发现船型选择器相机在入树前调用 `look_at()` 的两条错误日志；改用 `look_at_from_position()` 后复跑已消失。Headless 退出仍报告一条 DummyShader RID 清理告警。

F3 的帆船物理诊断展示缓存快照中的帆力、已测偏航力矩、船舵处水速、查询次数和物理计时；显式偏航阻尼单独标记为估算值。UI 改动没有增加风场或波浪采样。

航行文本和小仪表仍按 HUD 既有 0.10 秒节奏更新（约 10 Hz）；节点和主题在初始化时创建，UI Scale 切换不在逐帧重建 Theme，也不改变物理步中的采样预算。一次 Headless 集成记录的帆船物理片段平均/P95 约 246/323 μs，仅供该次运行观察，不能代表 Forward+ 帧率或 M2 GPU 性能。
