# Nordic 28 V1.1：视觉帆装挂点对齐

## 结论

穿模来自旧实验船的视觉与物理主帆枢轴共用位置。旧主帆视觉枢轴在船体局部 `Y=0.65 m`，三角帆脚又比枢轴高 `0.08 m`，所以帆脚约在 `Y=0.73 m`。Nordic 28 导入适配后，桅杆位置附近的舱顶约为 `Y=1.392 m`，视觉帆脚低了约 `0.66 m`，因此进入舱顶和甲板。

已把 Nordic 28 的视觉帆装挂点与 SailboatLab 的物理挂点分开。视觉锚点从适配后的 GLB 顶点扫描推导，并由 Nordic 28 专用视觉 Resource 控制净空和搜索范围。气动力、水动力、浮力和船体受力仍读取原来的 `SailboatLabProfile`。

## 最终视觉挂点

位置均为船体 `VisualRoot` 局部坐标，单位为米。GLB 扫描得到船长 `7.999 m`，桅杆站位 `Z=0`，该处舱顶高度约 `Y=1.392 m`。

| 锚点 | 局部位置 | 说明 |
|---|---:|---|
| `VisualMastBase` | `(0, 1.362, 0)` | 舱顶向下嵌入约 0.03 m，避免桅杆悬空 |
| `VisualMastTop` | `(0, 6.012, 0)` | 由 4.65 m 视觉桅杆长度推导 |
| `VisualBoomPivot` | `(0, 1.866, 0)` | 基于舱顶扫描高度，再按横杆全摆幅所需净空自动抬高 |
| `VisualMainHead` | `(0, 5.832, 0)` | 位于桅顶下方约 0.18 m |
| `VisualJibHead` | `(0, 5.832, 0)` | 与桅杆上部连接 |
| `VisualJibTack` | `(0, 1.961, -3.550)` | 从船首和前甲板几何推导 |
| `VisualJibClew` | `(0, 1.669, -1.150)` | 保持 2.4 m 视觉帆脚长度，并高于甲板扫描面 |

主帆 boom 枢轴高于桅杆站位舱顶约 `0.474 m`。将 boom 圆柱半径计入后，主帆横杆/帆脚在测试角度 `0°、±30°、±60°、±70°、±80°` 的最小舱顶净空约 `0.20 m`（最小值出现在中位），其余角度约 `0.288–0.363 m`。自动抬升依据沿横杆摆幅对导入船壳顶点的扫描结果，不使用物理挂点。

Jib 帆脚扫描净空在 `0°/±30°` 约 `0.182 m`，在 `±60°/±70°/±80°` 约 `0.152–0.157 m`。Jib 不是本轮重点，当前仍留有正净空，但余量小于主帆。

## 物理与视觉分离

- 新增 `Nordic28VisualRigAnchors`，只配置视觉桅杆、boom、主帆网格和 Jib 网格。
- 视觉参数独立放入 [nordic28_visual_rig_profile.tres](../../resources/sailing/nordic28_visual_rig_profile.tres)，包括 mast step 嵌入量、boom 净空、中心线和舱顶扫描范围、Jib 甲板净空等。
- 主帆视觉仍跟随 `actual_sail_angle_rad`，Jib 视觉仍跟随 `actual_headsail_angle_rad`；AUTO/MANUAL 不改变这条同步路径。
- `SailboatLabBody` 不再把物理主帆/Jib 锚点复制给视觉网格。它仍用原物理 Profile 计算受力和力臂。

本轮未改动 `sailboat_lab_profile.tres` 中的物理值：主帆枢轴 `(0, 0.65, -0.75)`、主帆压力中心偏移 `(0, 2.4, 0.8)`、Jib 物理 Head `(0, 4.95, -0.75)`、Tack `(0, 0.65, -3.55)`、Clew `(0, 0.65, -1.15)`。帆面积、质量/重心、龙骨、舵、阻尼和 AUTO 曲线也未修改。

## 修改文件

- `resources/sailing/nordic28_visual_rig_profile.gd`
- `resources/sailing/nordic28_visual_rig_profile.tres`
- `scripts/nordic28_visual_rig_anchors.gd`
- `scripts/sail_triangle_visual.gd`
- `scripts/sailboat_lab_body.gd`
- `scenes/boats/SailingBoat8m.tscn`
- `tests/test_sailboat_navigation_instrument.gd`
- `tests/test_sailboat_aerodynamics.gd`
- `tests/test_sailboat_headsail.gd`

测试调整还将旧 `SailPivot` 路径及“Jib 视觉坐标必须等于物理坐标”的过期断言换成新视觉 rig 断言。

## 验证

`tests/test_sailboat_navigation_instrument.gd` 的 Headless 几何日志记录了以上 GLB 推导挂点和摆幅净空，94 项检查通过。覆盖主帆 `0°、±30°、±60°、±70°、±80°`、Jib 开关，以及视觉根节点横摇 `0°、5°、10°` 下的相对净空。AUTO/MANUAL 下也分别验证实际 `+70°/-70°` 角度同步到 boom 枢轴。

其余相关 Headless 回归通过：

- 气动力：321 项。
- 独立 Jib：47 项。
- AUTO 操帆：57 项。
- 水动力：60 项。
- 浮力与动态海浪：87 项。

气动力性能测试中采样预算仍为每物理步 1 次 WindField、正常动态海浪 4 次 WaveSampler。本轮没有增加物理采样或物理更新步骤。

Main Headless smoke 退出码为 0；该模式没有渲染设备，关机时输出一个 `RendererDummy` shader RID leak，因此它不能代替 Forward+ 视觉验收。当前未制作新截图，也未在 GUI 中人工检查所有角度。请在 SailboatLab/Main 的 Forward+ 画面中最终确认帆布与船壳的观感；本轮日志验证的是 GLB 网格采样得到的几何净空。

## 已知边界

- 横摇 `0–10°` 测试是验证同一刚体上的船壳和 rig 一起旋转时相对几何不变，不是动态波浪中逐帧船体倾斜的可视化录像。
- Jib 大帆角仍有约 `0.15 m` 净空，视觉模型厚度、阴影或网格贴图可能让它看起来更接近前甲板。
- 舱顶估计基于 GLB 顶点在船体中心线附近的高度采样；若替换船壳网格，应重新运行导航仪表测试中的 rig 净空断言。

**物理受力点未变；本轮改动仅改变 Nordic 28 可见帆装的位置与几何。**
