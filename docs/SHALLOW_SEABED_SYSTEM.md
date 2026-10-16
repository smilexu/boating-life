# 浅海海床系统

本系统在正式 `main.tscn` 中以 `ShallowSeabedManager` 作为可关闭的子系统运行。它读取项目现有的 `GeoReference` 与本地 EMODnet DTM 2024 水深缓存，不创建第二套 GPS、水深或海洋系统。

## 坐标与数据

- 游戏坐标沿用 `GeoReference`：X 向东、Y 向上、Z 向南，1 单位为 1 m；海床区块索引用 `(east, north)`，其中 north = `-world_z`。
- 地理坐标转换使用 `GeoReference.world_to_geodetic()`，水深使用 `BathymetryManager.get_depth_at_world_position()`。
- 输入水深来自 `assets/geodata/processed/bathymetry/grid_metadata.json` 指向的 EMODnet Digital Bathymetry DTM 2024 ERDDAP 数据。垂直基准是 LAT；有效水深为 LAT 以下负高程取反后的正值。来源网格为 0.0625 角分，Malmö 附近约 65 m 东西向、116 m 南北向。网格的来源、许可及下载记录见 `docs/TERRAIN_DATA.md`。
- 海床高程用 `-(depth_m + water_surface_above_lat_m) + visual_relief` 对齐游戏水面。默认 `water_surface_above_lat_m = 0.5 m` 是视觉对齐量，不是测绘改正，也不改变海图读数。水深无效、含陆地或超出覆盖范围时不建立三角形。
- 视觉网格延伸到水深 9 m，为现有 6 m 透视范围提供隐藏退场边距；9 m 不是导航深度边界。模型没有底壁，避免 6 m 处出现竖直切口。超过该深度不生成海床或礁石。

## 区块、LOD 与缓存

- 区块为 128 × 128 m，按固定世界坐标取整，内容不依赖加载顺序。
- 船周围 300 m 以内使用近 LOD，最多显示到 600 m；卸载半径为 704 m，并有 32 m 的 LOD 滞回。中心区块每 0.5 秒检查一次，只在船跨入新区块后更新需求。
- 近、远顶点间距默认分别为 16 m 与 32 m。当前 DTM 的有效水平分辨率约 65–116 m，网格对其作连续插值并承载小幅视觉起伏，不代表新增的实测地形细节。
- 每帧最多处理一个扫描/建网任务。已构建网格有 24 项 LRU 缓存；浅水扫描结果缓存上限 512 项。场景树添加、移除及 MultiMesh 操作均在主线程执行。
- 近/远 LOD 的区块边界共用远 LOD 的高度、深度和法线锚点，减少 T 接缝。所有视觉 relief 使用连续世界坐标噪声，因此跨区块稳定。

## 海床与材质

- 每块浅水区从真实水深采样建立 `ArrayMesh`，用有限差分估计法线。缺失、陆地或超深数据会阻止相应三角形生成，不会被当成 0 m 水深。
- 着色器通过连续权重混合沙地、泥地和岩地；规则由深度、坡度及低频世界坐标噪声确定，避免区块各自随机造成棋盘边界。细节纹理是程序化美术近似，不是真实底质分类。
- 微地形振幅默认宽尺度 0.15 m、细尺度 0.04 m。它仅改变海床外观，不影响 `BathymetryManager`、水深仪或船舶安全判定。
- `ShallowReefGenerator` 用 5 个确定性低面数岩石变体，并按固定世界候选网格、种子 76123、实际水深、局部坡度和程序化岩性权重筛选。沙底稀疏、岩底较密、泥底较少；岩石使用每块每变体一个 `MultiMeshInstance3D`，不带碰撞体、不投射阴影。
- 现阶段没有实测海床底质分类数据。材质与礁石分布属于风格化近似；礁石种类、尺寸和密度可以通过 `ShallowSeabedManager` Inspector 参数调节。

## 主场景控制

`scenes/main.tscn` 已加入 `ShallowSeabedManager`。默认海床和礁石启用；调试 UI 默认隐藏。

| 操作 | 效果 |
| --- | --- |
| F6 | 开关现有海面材质的浅海透视 Uniform |
| F7 | 开关海床区块系统 |
| F8 | 显示/隐藏浅海统计面板 |
| Shift+F8 | 显示/隐藏区块边界 |
| Ctrl+F8 | 开关程序化礁石 |
| Alt+F8 | 开关近/远 LOD 着色诊断 |

统计面板报告激活/加载块、LOD 分布、已加载三角形、岩石实例、队列长度及平均/最近一次区块构建 CPU 时间。该面板仅供开发调试，不显示在默认玩家界面。

## 验证

- 图形验证脚本：`godot --path . --script res://tools/capture_shallow_seabed.gd`。它实例化正式主场景，冻结船只/世界时间，使用 Malmö 起始位置与真实离线水深，并保存对照图到 `docs/shallow_seabed/`。
- 区块卸载/返回确定性验证：`godot --headless --path . --script res://tools/test_shallow_seabed_streaming.gd`。脚本把暂停船只移动到起点外 1.2 km，检查起点块已卸载，再返回比较区块网格与礁石坐标签名。
- 代码/资源检查：`godot --headless --editor --path . --quit`；主场景检查：`godot --headless --path . res://scenes/main.tscn --quit-after 120`；浅海透视回归场景：`godot --headless --path . res://scenes/ShallowWaterTest.tscn --quit-after 120`。
- 本轮图形检查环境为 Godot 4.7.2 Forward+ / Metal 3.2，Apple M2 Pro，1920 × 1080。海床稳定后采样 180 帧：正式船尾镜头 68.2 FPS / 14.66 ms 平均帧时；礁石近景 76.3 FPS / 13.10 ms。每块建网平均约 5.60 ms，最近一次约 3.31 ms。此为本机、此场景的单次样本，不是跨设备性能承诺或对照基准。
- 初始 Malmö 位置查询为 55.60587° N, 12.96300° E，实际 DTM 水深 2.2438 m LAT，有效且来自 EMODnet DTM 2024。最近拍摄的礁石约距船 27.1 m，查询水深 2.2260 m LAT。
- Headless 往返验证：起始区块 `(104, -82)` 被移到 `(104, -73)` 后卸载；返回时该块三角形数量和每个礁石位置签名一致。统计块数可能因卸载滞回在返回后多于最初数量，这是半径策略的预期结果。
- 稳定状态初始邻域：69 块、17 近 LOD / 52 远 LOD、3,574 个已加载三角形、163 个礁石实例，等待队列为 0。切换到冬季深夜截图时统计数量不变，海床随夜景变暗。
- GUI 捕获工具正常结束时 Godot 在退出阶段输出 RenderingDevice RID 泄漏警告；本轮没有 Shader 编译或场景运行脚本错误。该退出警告尚未归因，不据此判断正常持续运行中的资源泄漏。

图形记录：

| 视角 | 截图 |
| --- | --- |
| Malmö 起始点船尾视角 | ![Malmö 船尾视角](shallow_seabed/01_real_start_third_person.png) |
| 斜俯视海床 | ![斜俯视海床](shallow_seabed/02_real_start_oblique.png) |
| 近礁石视角 | ![真实数据生成的浅水礁石](shallow_seabed/06_real_seabed_reef_closeup.png) |
| 水深有效性诊断 | ![水深透视遮罩](shallow_seabed/07_transmission_mask_diagnostic.png) |
| 近/远 LOD 诊断 | ![LOD 可见性](shallow_seabed/08_lod_visibility_diagnostic.png) |
| 冬季深夜 | ![深夜海床回归](shallow_seabed/09_winter_night_seabed.png) |

## 扩展点与限制

以后接入真实底质分类时，替换 `_material_weights()` 的代理规则；接入更多礁石资产时，扩展 `ShallowReefGenerator` 的共享变体库和区域选择；海草或鱼群应作为独立的浅水生态层，读取同一套区块键、水深查询与确定性种子，而不要塞入水深或海床网格生成代码。

当前水深分辨率较粗，岸边无效采样采取保守裁切，可能形成小缺口或相对海图海岸线略有偏移。水下画面仍受现有水面透视/光照效果影响；未制作真实折射、焦散、底质数据、碰撞礁石或搁浅判定。动态船只航行的长时间人工视觉验收仍需在游戏中完成。
