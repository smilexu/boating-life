# S1-C3：帆船方向识别、实时航行仪表与操舵诊断

日期：2026-10-21  
Godot：4.7.2  
范围：仅 SailboatLab 的视觉船体与只读航行诊断

## 交付内容

### 测试船外形

新增 [sailboat_lab_hull_visual.gd](../../scripts/sailboat_lab_hull_visual.gd)，在场景启动时一次性生成低面数船体与甲板网格。船首位于局部 `-Z`，从窄尖艏逐渐扩宽；船尾位于局部 `+Z`，保持宽平艉。甲板轮廓也从艏部向艉部展开。网格不参与碰撞或物理计算。

原 `CollisionShape3D` 仍为 `BoxShape3D(2.5, 1.2, 7.4)`；帆船质量、质心、浮力点、龙骨和舵作用点以及气动/水动力公式均未改。

在船尾甲板上方增加黄色舵角标记。它跟随水下 `RudderPivot` 使用同一个 `actual_rudder_angle_rad`，无碰撞、无物理作用，便于从第三人称视角确认舵叶方向。

### 实时俯视仪表

新增 [sailboat_navigation_instrument.gd](../../scripts/sailboat_navigation_instrument.gd)，由现有 `SailboatLabDebugPanel` 创建为屏幕右上角独立 Panel。左侧原有六个调试 Tab 保持原样，开发者可以一边查看仪表，一边在左侧调节舵角和本地风向。仪表宽度随视口限制在 270–320 px，高 408 px；窗口缩放时保持右上定位。鼠标事件被忽略，不影响左侧调试控件。

船体示意固定为艏向上，是相对船体的仪表，不是北向地图。环形参照上显示真风、视风及实际 COG 方向；箭头从外圈指向船体代表风的来向，绿色箭头显示船体实际移动方向。仪表同时显示：

- `HDG`：由刚体当前世界 Transform 的船首方向计算。
- `COG`、`SOG`：由刚体水平线速度计算。低于 0.15 m/s 时隐藏 COG 方向并标为不可靠；SOG 同时显示节与 m/s。
- 真风和视风：显示速度、世界罗盘来向和相对船首角。
- 主帆：实际角与目标角；示意 Boom 只跟随实际角。
- 船舵：实际角、左右舷方向、机械限位。
- 横倾、`COG−HDG` 航向与航迹差，以及单独标出的龙骨侧滑角 `β`。

正舵角沿用当前 C2 约定，表示舵叶转向右舷；A 为左舵，D 为右舵。此显示描述舵角方向，不把它与实际转向或航迹方向混为一谈。

## 方向和单位

[sailboat_navigation_math.gd](../../scripts/sailboat_navigation_math.gd) 提供仪表和测试共用的纯方向转换：

```text
forward_world = -global_basis.z
compass_bearing = fposmod(rad_to_deg(atan2(direction.x, -direction.z)), 360)
relative_bearing = wrapf(bearing - heading, -180, 180)
SOG_kn = horizontal_speed_mps × 1.94384449
```

因此局部 `-Z` 指北、`+X` 指东，罗盘方位为北 000°、东 090°、南 180°、西 270°。`COG−HDG` 是世界航迹相对船首的夹角；`β` 则是现有龙骨水动力计算出的侧滑角，分别显示。

WindField 输出空气实际运动方向 `wind-to`。仪表显示来向时只反转一次：`wind-from = -wind-to`。视风来向同样从 S1-C1 物理计算缓存的视风速度向量反转得到，不复制真风数据。风箭头按相对船首角旋转，且箭头尖端朝船体。

俯视 Boom 与舵叶的角度示意使用 `Vector2(sin(angle), cos(angle))`，零度沿局部 `+Z` 向艉，正角朝右舷。三维船舵标记也直接同步实际舵角。

## 数据来源与运行成本

帆船刚体增加只读 `get_navigation_snapshot()`，只读取现有物理步缓存的风向量、风况、帆/舵实际角、龙骨侧滑、横倾，以及刚体 Transform 和速度。不会调用 WindField 或 WaveSampler，也不参与刚体力学。仪表每 0.1 秒取一次快照并重绘；没有增加物理子步、物理采样、Mesh 每帧重建或物理节点。

测试检查调用仪表刷新前后刚体 Transform、速度以及最近一物理步采样计数不变。未进行单独 GPU/CPU 帧时间基准；新增渲染的实际成本仍需在 Forward+ 画面中测量。

## 测试结果

| 检查 | 结果 |
|---|---|
| 导航方向和仪表专项测试 | 40 项通过 |
| 帆船空气动力回归 | 308 项通过 |
| 帆船龙骨/舵水动力回归 | 60 项通过 |
| 浮力与动态海浪回归 | 87 项通过 |
| 浅水波浪约束回归 | 80 项通过 |
| WindField 回归 | 23 项通过 |
| SailboatLab headless 场景运行 60 帧 | 退出码 0 |
| Godot headless Editor 资源/脚本扫描 | 退出码 0；退出时有既有 ObjectDB 泄漏提示 |
| `git diff --check` | 通过 |

新增 40 项测试覆盖罗盘四方位、相对方位跨北向、风速矢量到来向的反转、左右风镜像、Boom 左右投影、节换算、低速 COG 门限、船首艉部网格比例、碰撞盒和质量未变、Transform 航向、真实本地 WindField 来向、船速变化后的视风差异、实际帆/舵视觉同步、右上角独立 Panel 布局，以及仪表不修改刚体或发起额外采样。

动态海浪回归仍保持四点浮力、每物理步最多四次 WaveSampler 查询；S1-C1 回归仍保持每步一次 WindField 查询。相关物理测试仅验证逻辑回归，不是 Forward+ 渲染帧率基准。

## 人工测试方式

运行：

```sh
godot --path . scenes/SailboatLab.tscn
```

1. 从斜上方查看测试船：尖艏为局部 `-Z`，宽平艉为 `+Z`；右上仪表船体图标始终艏向上。
2. 在左侧“风与主帆”Tab 调整主帆目标角，观察 Boom 的实际角追随；滑块与物理角存在追随时，面板同时显示实际值和目标值。
3. 按住 A / D，或调整舵角滑块，观察黄色船尾标记与仪表黄色舵叶；松开 A / D 后回中。
4. 使用左侧本地风向测试按钮切换左舷、右舷横风。仪表的青绿色真风来向应镜像；橙色视风会结合船速变化。
5. 航速达到 0.15 m/s 后观察绿色 COG 箭头，并与 HDG 和 `COG−HDG` 对比。静止时不应出现随机航迹箭头。
6. 让船建立航速后打左右舵，观察 HDG 和 COG 如何分别变化。静止打舵只应转动舵叶，不应凭空产生显著转向。

本次在 Apple M2 Pro 的 Godot 4.7.2 Metal Forward+ 环境启动了 SailboatLab，启动日志无脚本错误；但无法取得并检查实际画面截图，因此船体外形辨识度、左右面板并排效果、箭头观感和舵标记可见性**仍待人工视觉验收**。Windows Forward+ 也未验证。

## 文件

本阶段新增：

- `scripts/sailboat_lab_hull_visual.gd`（及 Godot UID）
- `scripts/sailboat_navigation_math.gd`（及 Godot UID）
- `scripts/sailboat_navigation_instrument.gd`（及 Godot UID）
- `tests/test_sailboat_navigation_instrument.gd`（及 Godot UID）
- `docs/sailing/S1-C3_REPORT.md`

本阶段修改：

- `scenes/SailboatLab.tscn`
- `scripts/sailboat_lab_body.gd`
- `scripts/sailboat_lab_debug_panel.gd`

## 已知限制

- COG 是当前刚体世界水平速度方向；现阶段水流速度为零。将来引入海流后，需要明确区分对地航迹与对水运动方向。
- 四点浮力原型主要针对正立附近姿态；接近倾覆时 Euler 横倾读数不作为船舶姿态仪表。
- 三维舵角辅助是甲板上的诊断标记，不是实际舵机/舵柄模型。
- 屏幕安全区、低分辨率裁切和白天/夜间对比尚需在图形窗口中人工确认。
