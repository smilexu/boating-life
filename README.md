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
- F3 面板可切换画质优先 / 平衡 / 性能优先三个 3D 分辨率档（100% / 75% / 67%）、`30 FPS` / `60 FPS` / `Unlimited` 帧率上限以及窗口 / 全屏模式。首次启动时会结合显卡、处理器核心数和已连接显示器中最大的像素尺寸推荐初始画质；推荐只执行一次。玩家手动选择后会保存在 `user://quality_settings.cfg`，之后改变窗口尺寸、全屏状态或帧率上限不会覆盖画质。
- 小于 100% 时使用 Godot Forward+ 的 FSR 2.2 缩放 3D 渲染；HUD 和其他 2D UI 仍在窗口输出分辨率绘制。本项目没有实时动态分辨率。F3 详细诊断可查看窗口 framebuffer、当前显示器尺寸 / HiDPI 比例、Viewport 和估算的内部 3D 尺寸。Godot 将缩放应用于 3D buffer，不降低 UI 分辨率（[Viewport 文档](https://docs.godotengine.org/en/4.7/classes/class_viewport.html)、[Window 文档](https://docs.godotengine.org/en/4.7/classes/class_window.html)）。
- 画质优先保持现有 4096 阴影图集、SSR/SSAO、四级海面网格和四分之一分辨率云计算；平衡档将阴影图集降至 2048、减少云步数并略减海面细节；性能优先将阴影图集降至 1024、关闭 SSR/SSAO、降低云采样并使用三级海面网格。各档复用同一场景和材质。
- 30 FPS 档关闭 VSync，由 Godot 限帧；60 FPS 档启用 VSync 并设 60 上限；Unlimited 关闭 VSync 并取消引擎限帧。左上角显示的是实际 FPS，不是所选上限。
- 太阳高度以地平线上方角度表示（3°–75°）。方位以摄像机前向（世界 `-Z`）为 0°，顺时针增加；这是原型内的方向接口，不是地理罗盘方位。
- 天空由 Godot 原生 Sky Shader 生成，包含大气渐变、地平线薄雾、程序化层云与卷云。云层在半分辨率通道绘制；天空辐照贴图以实时 256×256 更新，让缓慢移动的云参与船体与水面的环境反射。
- Forward+ 使用 AGX 色调映射、PSSM2 方向光阴影、屏幕空间反射、轻量 SSAO、低强度 Glow 和深度大气雾；这些效果用于海水反射、船体层次与远端地平线融合。实际帧率请以目标设备运行时为准。
- 本轮画面检查与本机帧时间数据记录见 [`docs/WEATHER_VISUAL_CHECK.md`](docs/WEATHER_VISUAL_CHECK.md)。
- 画质档位首次推荐规则和本机性能对照见 [`docs/PERFORMANCE_REPORT.md`](docs/PERFORMANCE_REPORT.md)。本轮在 Apple M2 Pro 上测量；M4 目标机仍需复测。

## GPU 粒子船舶尾流

- 当前唯一维护的尾流实现是 GPUParticles3D + ParticleProcessMaterial + shaders/particle_wake_foam.gdshader，位于独立测试场景 scenes/SimpleParticleWake.tscn。测试沿用正式船只、动态海面、WaveSampler、天空与摄像机，不接入正式主场景。
- 按 F6 / F7 / F8 / F9 测试停止、2、7、12 m/s；F10 / V 切换 S 弯；F11 / K 只切换关闭 / GPU 粒子尾流；F12 / O 切换船尾与倾斜俯视镜头。
- 旧版动态 Mesh / Water Trail 实现已从项目中移除，不再维护或参与测试。
- 对照条件、运行命令与性能限制见 [docs/PERFORMANCE_REPORT.md](docs/PERFORMANCE_REPORT.md) 和 [docs/SIMPLE_PARTICLE_WAKE_REPORT.md](docs/SIMPLE_PARTICLE_WAKE_REPORT.md)。

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

## Øresund 地理轮廓原型

- `scenes/OresundRegion.tscn` 是独立地区场景，并已挂入 `scenes/main.tscn`。动态海洋仍使用原来的 Boujie Ocean；仅将它的远端面延伸到 60 km，以便与区域海岸场景相接。
- 经纬度权威来源为 WGS84。`resources/oresund_georeference.tres` 将 WGS84 ECEF 转成局部 ENU：Godot `+X` 向东、`+Y` 向上、`-Z` 向北，1 单位=1 米。地图原点为 55.700000°N、12.750000°E。
- 按 `M` 切换地图调试/俯视检查，再按一次返回船尾镜头。调试视图用橙色圆点和“船只”标签实时标出船在地图上的位置，并显示近似 WGS84 坐标；同时显示 5 km 网格、原点、Malmö/Copenhagen/Øresund Bridge 参考标记和两城直线距离。
- 海岸线使用 OpenStreetMap `natural=coastline`，处理程序位于 `tools/build_oresund_map.py`。数据范围、离线生成方式和 ODbL 分发要求见 [`assets/geodata/README.md`](assets/geodata/README.md)，坐标规则见 [`docs/GEOREFERENCE.md`](docs/GEOREFERENCE.md)。
- 当前工作树包含两份带 OSM 时间戳的原始 Overpass extract 和处理后的海陆网格。处理器以海上原点为水域种子，通过海岸线交叉奇偶性生成 15 m 分类栅格，再输出 15/80/250 m 简化网格。已有快照可用 `.venv/bin/python tools/build_oresund_map.py` 离线重建；更新数据用 `.venv/bin/python tools/build_oresund_map.py --download`。调试面板显示 `© OpenStreetMap contributors · ODbL-1.0`，分发要求见地理数据说明。
- 当前地图阶段包含海岸线与简化高程地形，不包含植被、建筑、桥梁模型或航线。

## Øresund 高程地形

- `scenes/OresundRegion.tscn` 加载 Task 7 的海陆边界和 Mapzen Terrarium 高程生成的分块地形。地形数据只覆盖 OSM 分类为陆地的区域，动态海洋仍是原来的系统。
- 初次重建：`.venv/bin/pip install -r tools/requirements-terrain.txt`，然后运行 `.venv/bin/python tools/terrain/fetch_tiles.py --zoom 11` 和 `.venv/bin/python tools/terrain/build_terrain.py --zoom 11`。前者缓存公开 AWS 瓦片，后者生成可重复加载的 10 km 分块网格。
- 当前地形网格间距为 100 m；要调整游戏中整体高程，可在 `OresundRegion` Inspector 调整 `terrain_vertical_offset_m`。生成时还会用距海岸线 60 m 的中位高程校准一次统一基准，并把过低陆地点托在海平面上 0.5 m。
- 草地、土壤、沙地、岩石和城市地表颜色是根据高程、坡度、海岸距离和城市参考点生成的美术近似，不代表真实土地覆盖分类。
- 数据来源、瓦片样本解码、许可署名和已知限制见 [`docs/TERRAIN_DATA.md`](docs/TERRAIN_DATA.md)。

## 目录

- `scenes/`：Godot 场景
- `scripts/`：GDScript 脚本
- `assets/`：美术与音频素材
- `assets/geodata/`：OSM 海岸线输入说明与处理后地区数据
- `assets/terrain/`：Mapzen Terrain Tiles 原始缓存与生成的地形网格
- `docs/`：开发文档
- `tools/`：离线地区数据处理脚本
