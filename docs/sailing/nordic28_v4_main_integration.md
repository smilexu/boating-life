# Nordic 28 V4.1：Main 船舶菜单集成

## Main 架构与接入位置

Main 入口是 `scenes/main.tscn`，玩家船的既有导航门面仍是 `PlayerBoat/MotionRoot`（`BoatController`）。这层被相机、深度监控、地图、区域交互、音频和任务系统引用，因此本轮保留它，不替换 Main 船舶架构。

I 键选择器由 `scripts/boat_hud.gd::_build_vessel_picker()` 创建；该 HUD 的 `_unhandled_key_input()` 处理 I 开关，Esc 关闭。它目前按项目已有模式显式构建动力艇和帆船两张卡片，而不是读取独立船型数据库。每张卡片使用 `scripts/vessel_preview_card.gd`，在隔离的 `SubViewport` 中复制对应可见 Mesh 供预览；预览不创建第二艘刚体或控制器。Nordic 28 使用 Main 场景中唯一的 `PlayerBoat/SailingBoat8m` 实例，资源来源仍是 `scenes/boats/SailingBoat8m.tscn`，与 SailboatLab 共用。

## 船型选择与生成

帆船卡片现在显示：

- 名称：**Nordic 28**
- 类别：休闲巡航帆船 · 风帆推进
- 信息：船长约 8.0 m、可见船宽约 2.75 m、Profile 吃水 0.90 m、主帆与前帆面积、独立操控和 AUTO 操帆支持
- 描述：适合近海巡航与悠闲航行

动力艇仍是启动时默认船型。I 打开/关闭原选择器；点卡片按钮后由 `BoatController.set_sailing_enabled()` 切换。选择器列表仍在现有 HUD 内，不属于 F3 调试菜单。

选择 Nordic 28 时，`BoatController` 先围绕当前玩家船位尝试 14 m 侧向、前后候选点，随后尝试 21 m 候选点。每个候选点必须通过 `NavigationDepthProvider` 的帆船吃水与安全余量检查，并通过现有 PhysicsDirectSpaceState 碰撞形状查询。若没有候选点满足条件，保留原来的 `SailingBoatSpawn` Malmö 外海标记作为回退位置。

本次 Main 初始船位附近的粗略 DTM 样点约为 2.24 m LAT；被选中的近距离候选通过 Profile 0.90 m 吃水加 0.50 m 游戏余量判定。附近样点标记为非航海级参考数据，不能当作真实航行安全保证。固定外海回退标记的 DTM 样点约为 5.56 m LAT，同样是粗略数据。

帆船仍执行 `prepare_for_main_spawn()` 的一次性浮态初始化：按当前位置采样当前 WaveSampler 水面并将刚体置于 Profile 规定的静态浸没量，初始线速度和角速度清零。已装配在 `VisualRoot` 中的 Nordic 28 -0.30 m 视觉吃水偏移不会再被额外叠加。切回动力艇时，Main 导航门面同步到帆船的当前位置与航向，旧帆船冻结、隐藏并关闭碰撞；再切回时可继续使用唯一帆船实例。

## 控制、相机与 HUD

- A/D：沿用项目左右舵输入，帆船刚体应用已有舵角限位和转动速度。
- Z/X：沿用主帆目标角控制；J/L：沿用前帆目标角控制。
- T：帆船模式由共享帆船实体切换 AUTO/MANUAL 自动操帆。自动巡航控制器看到 `supports_autopilot() == false` 后不接管帆船。
- 舵轮动画继续读取实际舵角；主帆/Jib 视觉、动态鼓风、Logo 与索具继续由同一实体驱动。
- 选择器打开时临时关闭帆船键盘控制并显示鼠标，关闭后按原状态恢复；没有覆盖全局 InputMap。

Main 复用 `PlayerBoat/FollowCameraRig`，没有加载 SailboatLab 摄像机。相机以能力接口 `supports_sail_trim()` 判断较高帆装，将常规跟随距离从原设置至少调整到 18 m；滚轮可在 4–36 m 范围内调整，原 O 键 God View 仍可用。切回动力艇后恢复原 `follow_distance`。

右下角既有帆船操作 Panel 在帆船模式显示航速、船首航向、真实风速/风向、相对来风、主帆/Jib/舵角和 AUTO 状态；详细模式继续显示 SOG/COG/TWS/TWA/AWS/AWA 等已有指标。动力艇模式隐藏帆船 Panel 并恢复原罗盘/动力艇 HUD，不显示虚构发动机数据。

## 环境、任务兼容性与物理范围

Main 的 `SailingBoat8m` 通过场景 NodePath 使用 Main 唯一的 `WindField` 和 `WaveSampler`；天气仍由 Main `WeatherStateController` 驱动正式风场。没有加入测试覆盖，也没有改动 Sea Prototype 的风浪服务。场景层级中 Main 仍只有一个 WindField 和一个 WaveSampler。帆船每个物理步保持一次 WindField 查询和四次 WaveSampler 查询。

帆船仍不支持货运/港口服务任务和自动巡航。现有能力接口在帆船模式返回 `supports_cargo() == false`、`supports_autopilot() == false`；相关入口会拒绝或说明不支持，没有把发动机油门或固定巡航速度套用到风帆船。

本轮未修改质量、吃水 Profile、帆面积、压力中心、帆力/水动力、浮力、阻尼、AUTO 曲线、天气或动力艇运动参数。

## 修改文件

- `scripts/boat_hud.gd`：将已有帆船选择卡命名为 Nordic 28，展示类别和实际能力信息。
- `scripts/vessel_preview_card.gd`：给卡片名称、类别、信息标签添加稳定节点名，支持集成检查；信息区留出四行描述空间。
- `scripts/boat_controller.gd`：切换帆船时优先在玩家船附近进行深度和碰撞校验，保留原 Malmö 外海点作回退。
- `scripts/boat_follow_camera.gd`：针对支持操帆的船型自动拉远跟随距离，并增加滚轮拉近/拉远。
- `tests/run_s1_c8_integration.gd`：扩展 I 键、Nordic 28 卡片、就近安全生成、相机和重复切换检查。

没有修改 `scenes/boats/SailingBoat8m.tscn`、`scenes/main.tscn` 或 `scenes/Boat.tscn`：审计确认 Main 已实例化共用的帆船场景、接好正式服务，并有原有安全回退标记。

## 自动化验证

运行：

```sh
godot --headless --path . --script res://tests/run_s1_c8_integration.gd
```

结果：**0 项失败**。本次测试覆盖了 Main 场景加载、I 键打开和关闭、Nordic 28 名称/类型/信息、唯一共享帆船实例、附近候选生成/吃水余量/船首方向、正式 WindField/WaveSampler 引用、HUD、AUTO 能力、帆船/动力艇来回切换五轮、相机模式距离、鼠标滚轮缩放，以及 WindField/WaveSampler 查询次数。

本次短时 Headless 物理片段测得帆船物理代码平均/P95 为 **222/279 μs**，WindField 平均/P95 为 **9/15 μs**，WaveSampler 平均/P95 为 **150/167 μs**；每物理步为 **1 次风查询、4 次波浪查询**。这仅是 Headless CPU 采样，不能代表 Forward+ 帧率或 GPU 性能。退出时仍有 RendererDummy `DummyShader` RID allocation leak 提示；Headless 未创建图形渲染设备，不能据此判断 Forward+ 资源泄漏。

## 尚需人工验收

本轮没有执行 Forward+ 图形验收。请在 Main 中按 I 检查 Nordic 28 的帆装 3D 预览和卡片排版；选择后确认船位与玩家船相邻、镜头能完整观察桅杆/双帆，滚轮能缩放；检查真实天气下的帆布鼓风、木舵轮、HUD 和舵帆输入；切回动力艇确认发动机、相机、HUD 和自动巡航恢复。附近深度来自粗 DTM，仍需在画面中检查浅海床/岸边间距。
