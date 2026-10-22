# S1-C8：帆船接入 Main 场景

## 接入设计与实现

Main 中很多系统都通过 `PlayerBoat/MotionRoot` 读取玩家船只的位置、航向、吃水、音频和导航状态。直接替换这个节点会牵涉大量现有消费者。本阶段保留 `BoatController` 作为 Main 的导航与能力接口，并在同一 `PlayerBoat` 实例下放入一艘可选的 `SailingBoat8m` 刚体。选中帆船时，刚体成为唯一工作的船体；`BoatController` 只把刚体的平面位置、航向和纵向速度同步给既有 Main 系统。这样相机、地图、深度监控、风场调试、音频和区域系统继续使用原接口。

`SailingBoat8m.tscn` 是 SailboatLab 和 Main 共用的船体实体。Lab 保留自己的测试天气、风场、WaveSampler、摄像机和 DebugPanel；Main 中实例化同一实体，并将其 `wind_field_path`、`wave_sampler_path` 指向 Main 的唯一服务。没有复制物理模块，也没有在帆船场景里创建第二个风场或海浪系统。

### Main 船只架构审计

- Main 的入口为 `scenes/main.tscn`。玩家船来自 `scenes/Boat.tscn`；`PlayerBoat/MotionRoot` 是 `BoatController`，旁边是跟随相机 Rig。
- Main 多个现有系统把 `MotionRoot` 作为船只引用，包括跟随相机、HUD/罗盘、深度监控、WindField 调试、海岸/区域交互、音频和自动巡航。
- Main 已有单例场景节点 `WindField`、`WaveSampler`、`WeatherStateController`、海洋表面和水深服务。帆船直接读取 Main 的 `WindField.get_wind_details_at()` 和 `WaveSampler.sample_physics_surface()`，没有测试风场覆盖。
- `WaveSampler` 的 CPU 物理采样和 Shader 使用同一组有效波浪参数、世界坐标相位和时间；物理采样不使用摄像机距离淡出。Main 每物理步仍由帆船作四个浮力点查询，WindField 查询一次。
- 主场景地图与水深坐标使用项目 ENU 世界坐标；帆船船首仍为局部 `-Z`。船体波浪采样使用真实世界坐标，所以离开出生点后不依赖起始位置或相机位置。
- Main 的输入与导航消费者依旧看到 `BoatController`。自动巡航与货运对帆船报告不支持；帆船模式下港口服务面板会说明当前原型尚未接入，货运 API 返回 `unsupported_vessel`。

## 船体实体与选择

新增 `scenes/boats/SailingBoat8m.tscn`，包含一个 `RigidBody3D`、既有碰撞体、船体和甲板视觉、龙骨/船舵标记、桅杆、三角主帆与独立 Jib。空气动力、四点浮力、龙骨/舵水动力和 C7b 自动操帆仍由现有 Profile 与脚本负责。

`scenes/SailboatLab.tscn` 现在把同一个 `SailingBoat8m.tscn` 放入原 Lab 环境中，Lab 的风浪、相机和测试 UI 仍属于 Lab。Main 中的帆船初始隐藏、冻结且关闭碰撞；切换后启用它，并隐藏/停用动力船视觉、尾流和排气烟。切回动力船会冻结帆船、停用它的碰撞并恢复动力船视觉。每次切换只保留一个活动船体；Main 的 WindField 和 WaveSampler 数量不变。

船型选择通过 **I** 打开独立选择面板，不放在 F3 调试页。当前列表包含动力艇和 8 m 双帆帆船卡片：显示从现有模型网格构建的 3D 预览、船型、尺寸/吃水及动力或帆装信息；点击“选择这艘船”后立即走现有 `BoatController.set_sailing_enabled()` 切换流程。选择器打开期间鼠标可操作、手动船舶输入被屏蔽，天气和世界时间继续运行；I、Esc、关闭按钮或点击背景均可关闭。预览使用隔离 SubViewport，仅复制静态 Mesh，不创建刚体、音频或控制脚本；关闭时停止 SubViewport 更新。F3 继续只负责视觉与环境调试。初始仍选择原动力船。

## Malmö 帆船出生位置

动力船原始出生点保持不变。新增 Main 节点 `SailingBoatSpawn`，位于原点以西约 900 m，并保持原船首朝东。选择帆船时使用该标记生成；切回动力船时，Main 的运动代理和动力船视觉继续位于当前平面位置。

对出生标记运行 `NavigationDepthProvider` 检查，EMODnet DTM 2024 返回 **5.56 m LAT**。按 Profile 的 0.9 m 吃水和深度服务默认 0.5 m 余量，名义深度高于 1.4 m。该采样被标为 **Coarse DTM reference; not navigation-grade**，所以只可作为游戏出生点参考，不能证明真实航道或海床净空；需要在 Forward+ 场景中检查船体与浅海床视觉/碰撞。

## 控制、相机与 HUD

- A/D：使用原有左右舵输入和帆船已验证的舵角限位/限速。
- Z/X：主帆向左舷/右舷摆角，每次调整目标角 10°；J/L：Jib 调角。手动调帆时退出 AUTO。
- T：AUTO/MANUAL 操帆；AUTO 只更新两张帆的目标角，玩家继续手动掌舵。
- Space：暂停/恢复活动帆船刚体。ESC 设置菜单关闭时也会屏蔽帆船键盘控制。
- 默认模式为 MANUAL。C7b 的帆船 Profile 曲线原样使用：主帆 AWA 控制点含 `80.2° → 60°`、`108.1° → 79.9°`、`143.1° → 79.9°`，Jib 对应 `80.2° → 55°`、`108.1°/143.1° → 70°`；0–60°部分保留 C7a 控制点。左右舷符号镜像、滞回、NO-GO 和 Resource 限位未改。
- Main 复用 `FollowCameraRig`，没有启用 SailboatLab 摄像机。代理跟随刚体水平位置和船首航向，仍保持海面导航平面；船体升沉、横摇和纵摇由刚体自身显示。
- 既有 Main 状态 HUD 保留，并提示 I 选择船只。帆船模式将 SailboatLab 的相对航行仪表合并进右下角帆船控制 Panel：显示 HDG、COG、SOG、真风/视风箭头和速度/方向、主帆/Jib 实际与目标角、舵角、AUTO/NO-GO；同一面板下方提供 AUTO、Jib 开关和帆角按钮。仪表读取船体已缓存的导航快照，不新增 WindField 或 WaveSampler 查询。帆船模式隐藏重复的 Main 罗盘 HUD；打开 F3 时暂时隐藏该帆船面板并恢复罗盘，关闭 F3 后恢复面板。选择器独立于 F3 调试面板。
- BoatAudioController 在切换时重新绑定船体运动状态；帆船的 `has_engine()` 为 false，旧发动机音轨淡出，环境风雨海浪仍由 Main 音频管理器工作。

InputMap 中 W/S 为动力船加速/制动，A/D 为转向，Space 为暂停，T 为自动巡航。帆船复用 A/D、Space；增加的 Z/X/J/L 没有占用项目 InputMap 动作。帆船模式下 T 被帆船实体消费为 AUTO 切换，自动巡航控制器按 `supports_autopilot()` 拒绝帆船。没有改写全局 InputMap。

## 参数保留

没有修改帆船物理 Profile、气动/水动力公式、浮力、龙骨、舵、船体质量、刚体阻尼、海浪、风场、天气或动力船的推进参数。8 m Profile 的 3200 kg 质量、0.9 m 吃水、10.16025 m² 主帆、5.16 m² Jib、`REPLACE + linear_damping=0` 以及现有帆角/舵角限位均保留。C7b 曲线只从已有 Profile 读取，没有在 C8 重新调校。

## 修改文件

- 新增 `scenes/boats/SailingBoat8m.tscn`：供 Lab/Main 共用的帆船实体。
- 修改 `scenes/SailboatLab.tscn`：改为实例化共用实体。
- 修改 `scenes/Boat.tscn`、`scenes/main.tscn`：加入冻结的帆船实例和 Malmö 开放水域出生标记。
- 修改 `scripts/sailboat_lab_body.gd`：支持 Main 正式服务路径、按指定出生标记初始化、活动船控制门控和 Main 音频只读运动状态；Lab 默认重置/键盘行为保持原样。
- 修改 `scripts/boat_controller.gd`：提供船型切换/能力接口，并把帆船平面导航状态代理到现有 Main 船只接口。
- 修改 `scripts/boat_hud.gd`：I 键选择器、帆船状态与操帆 Panel、切换时音频绑定。
- 新增 `scripts/vessel_preview_card.gd`：隔离 SubViewport 的船型模型预览卡片。
- 修改 `scripts/game_menu.gd`：ESC 菜单打开时同步屏蔽帆船手动输入。
- 修改 `scripts/autopilot_controller.gd`：不支持自动巡航的船型不会接收/继续巡航指令。
- 修改 `scripts/cargo_economy_manager.gd`、`scripts/port_service_controller.gd`：明确禁用帆船原型的货运/港口任务入口。
- 新增 `tests/run_s1_c8_integration.gd`：Main 共享服务、切换、出生点、查询预算和能力门控 smoke test。

## 已运行检查

| 检查 | 结果 |
|---|---|
| `godot --headless --path . --script res://tests/run_s1_c8_integration.gd` | C8 原始集成版本曾通过，0 失败；本次将断言与切换操作更新为 I 选择器及预览卡片，但没有重新运行该测试 |
| Main 活动帆船 30 个物理 tick 的诊断快照 | 1 次 WindField + 4 次 WaveSampler/tick；帆船物理代码 avg/P95 495/1173 μs，波浪采样 323/717 μs，风采样 25/76 μs。headless 短窗口数据有噪声，不代表完整帧时间或图形性能 |
| `godot --headless --path . scenes/main.tscn --quit-after 120` | 退出码 0，Main 场景 headless 运行 120 帧 |
| `godot --headless --path . scenes/SailboatLab.tscn --quit-after 120` | 退出码 0，SailboatLab 共用实体 headless 运行 120 帧 |
| SailboatLab 自动回归 | 浮力 87、气动 321、水动力 60、独立前帆 46、AUTO 57、导航仪表 46、阻尼策略 17、快捷键 14、WindField 23、浅水波浪 80 项通过 |
| `git diff --check` | 通过 |

Headless 退出时出现一次 RendererDummy `DummyShader` RID allocation leak 提示，Main scene smoke 和场景加载都会出现；headless 未创建渲染设备，不能据此判断为 Forward+ 资源泄漏。浅水波浪测试也会因其独立夹具缺少 ShaderMaterial 输出一条预期 warning，80 项断言仍通过。

## 尚需人工验收与限制

本轮没有执行 Forward+ 可视化测试，也没有在 I 选择器迁移后重跑集成 smoke，因此不能宣称 M2 GPU/FPS、Windows 渲染或新选择器输入验收通过。请在开发版 Main 中按 I，检查两张卡片的 3D 模型预览和文字信息；切换船只后检查桅杆/双帆、出生位置、相机、HUD 与音频；确认船体没有穿海床或碰码头；在晴天/天气变化和中等海况下掌舵、手动调帆、开关 AUTO；航行数分钟后检查水面同步；再切回动力船并验证 W/S、A/D、自动巡航和音频。

已知限制：船型列表目前只有当前动力艇和一艘 8 m 帆船；新增船型仍需接入其模型和显示信息。帆船货运、港口任务和自动巡航未接入；没有测试真实 Malmö–Copenhagen 长航程、浅水/海岸碰撞和多船型复用。出生水深来源为非导航级粗 DTM。没有在本阶段调整近迎风 60°舵负担或其他帆船物理参数。

## 运行方式

```sh
godot --path .
```

运行后按 I 打开船只列表，查看动力艇和 8 m 帆船的 3D 模型预览与信息，再点击卡片底部的选择按钮。按 I、Esc、右上角关闭按钮或点击面板外区域关闭列表。切回动力船时重复选择对应卡片。F3 仅打开视觉/环境调试面板。
