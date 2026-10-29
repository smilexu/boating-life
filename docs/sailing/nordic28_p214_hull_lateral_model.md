# Nordic 28 P2.14：船体横向水动力单点模型

## 实现

`SailboatLabProfile` 新增 `hull_lateral_center_from_com_local_m`，含义为相对实际质心的船体局部偏移，默认 `Vector3.ZERO`。`SailboatLabBody` 读取该参数：零偏移继续走旧的质心阻力计算与 `apply_central_force()` 路径；非零时用

```text
v_point_world = v_COM_world + angular_velocity_world × (body_basis × arm_COM_local)
v_point_local = body_basis⁻¹ × (v_point_world − water_current_world)
```

横向 X 阻力只使用 `v_point_local.x`；纵向 Z 阻力仍使用质心相对水速。既有阻力函数和合力限幅只执行一次。纵向分量仍在质心施加，唯一的横向分量在质心相对偏移处施加；其 `arm × force` 只用于遥测，没有再加显式力矩。`apply_force()` 所需的船体原点偏移由 `COM_local + arm_COM_local` 转换得到。

实现位置：[sailboat_lab_profile.gd](../../resources/sailing/sailboat_lab_profile.gd#L117)、[sailboat_lab_body.gd](../../scripts/sailboat_lab_body.gd#L659)、[polar_test_runner.gd](../../scripts/polar_test_runner.gd#L597)。扩展遥测记录作用点、局部入流、横向力和力矩；它不增加 WindField 或 WaveSampler 查询。

## 几何估算

对 P2.3c 实际实例中的 `VisualRoot/HullModelAdapter/Nordic28Model/node_0` 网格应用完整 Mesh→RigidBody 变换后，以静态吃水水线 `body-local Y = −0.05 m` 裁切侧投影。该水线由 `rest_submergence=0.45 m` 与浮力点平均 `Y=−0.50 m` 推得。视觉装配的 `−0.30 m` 偏移已包含在网格变换中。

网格只有一个 surface，船壳与鳍龙骨合并。为避免把独立龙骨水动力已覆盖的区域算入船壳中心，估算时排除中心带 `|X| ≤ 0.25 m` 中 `Y < −0.60 m` 的投影片段。所得船壳侧投影面积约 `6.294 m²`，几何形心约为刚体局部 `(0.0067, −0.2828, −0.0044) m`。当前 COM 为 `(0, −0.65, 0) m`，因此完整形心减 COM 为约 `(0.0067, +0.3672, −0.0044) m`。

依据 P2.13“高度先留在 COM 附近、首轮只看 Z”的建议，独立 H-GEO Profile 使用 `(0, 0, −0.00438) m`，没有把几何估算的 Y 高度差作为首轮变量。对龙骨排除宽度 `0.20–0.30 m`、边界高度 `−0.50…−0.70 m` 做的敏感性检查，使形心 Z 约落在 `−0.0058…+0.0228 m`。GLB 合并网格让龙骨分区只能近似；候选 `−4.38 mm` 小于分区带来的约 `20–30 mm` 变化，不能视为可靠水动力中心，也不足以做有效性能校准。

## 配置与验证

独立 Profile：[BASE](../../resources/sailing/nordic28_p214_base_physics_profile.tres) 保持零偏移；[H-GEO](../../resources/sailing/nordic28_p214_hgeo_physics_profile.tres) 只改变新增中心参数。配置检查确认两者与 P2.3c 只有 vessel name 和该新参数差异；P2.3c Profile、正式 Nordic 28 以及 P2–P2.13 结果没有被本阶段覆盖。

| 数据 | 状态 | 实际 TWA | SOG | 侧滑 | 横倾 | 平均舵角 / 饱和 | 船体横向力 X | 船体偏航矩 |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| P2.5 BASE，−50° | HEADING_FAILED | −58.968° | 1.512797 kn | 23.3048° | −8.01294° | −35° / 100% | −177.316 N | 0 N·m |
| P2.14 BASE 零偏移 smoke，−50° | HEADING_FAILED | −58.968° | 1.512797 kn | 23.3048° | −8.01294° | −35° / 100% | −177.316 N | 0 N·m |
| P2.14 H-GEO 非零路径 smoke，−50° | HEADING_FAILED | −58.948° | 1.512552 kn | 23.3230° | −8.01318° | −35° / 100% | −177.432 N | +0.7772 N·m |

零偏移 smoke 与 P2.5 的 TWA、SOG、舵角、横向力完全一致，力合量误差 `0 N`，新增船体偏航矩为 `0 N·m`。H-GEO smoke 中 `−0.00438 m × −177.432 N = +0.7772 N·m`，与实际点力矩遥测一致；合力仍只施加一次。它相对 BASE 的变化很小：TWA `+0.020°`、SOG `−0.000245 kn`，舵仍 100% 饱和，不能据此声称航向或性能改善。

| 目标 TWA | 可用 BASE 参考 | H-GEO 正式对照 |
|---|---|---|
| −50° | P2.5 与 P2.14 零偏移 smoke：均 HEADING_FAILED | 不运行；仅完成单例力路径 smoke |
| −70° | 未找到对应 P2.5 工况 | 不运行 |
| −90° | P2.5：STABLE，实际 −90.446°，SOG 2.694 kn | 不运行 |

由于候选偏移小于网格分区不确定性，未执行 −70°、−90° H-GEO 性能测试，也未补跑 −70° BASE。风浪查询仍为每物理步 WindField `1` 次、WaveSampler `4` 次。所有新物理测试使用原稳定性阈值、60 Hz 模拟步长、发动机关闭、静水零振幅和原 AUTO Trim/PD 控制；失败状态原样保留。

## 结论

- 零偏移路径通过 P2.5 定量回归；新增非零分支通过一次真实刚体 smoke，`r × F` 与合力拆分遥测一致，未见 NaN/Inf、重复横向力或额外环境查询。
- 这次 GLB 估算不足以把 `−4.38 mm` 纵向偏移作为船型校准候选。不要把该偏移应用到正式 Nordic 28，也不要从这个单例推断迎风能力。
- 当前建议保留通用单点模型及默认零偏移接口；在船壳与龙骨可可靠分区或获得更可信水动力中心之前，不建议继续用这份几何估算做 H-GEO 三工况校准。若后续取得有分辨率的独立船壳网格，再评估真实中心并运行 −50°/−70°/−90°对照。

## 文件与可复现结果

- 代码/Profile：上列三处实现文件、两个 P2.14 独立 Profile。
- 几何检查：[inspect_nordic28_p214_hull_lateral_center.gd](../../tests/inspect_nordic28_p214_hull_lateral_center.gd)。
- Polar 回归与路径 smoke：[run_polar_p214_hull_lateral_model.gd](../../tests/run_polar_p214_hull_lateral_model.gd)。
- 结果目录：[polar_p214/p214_1793231593_512287](polar_p214/p214_1793231593_512287)，含对照 CSV/JSON、配置清单、Profile 快照及两个原 Polar Runner 的 checkpoint/结果文件。
- P2.14 指纹：`af2c2716ab17122109bc5dc8238de1e49523d8d3c498f2cd515fb75897805af4`。BASE/H-GEO Polar run ID 分别为 `polar_2026-10-28_23-53-13_077722`、`polar_2026-10-28_23-53-45_251714`。

已执行几何分析脚本、Profile/基线只读配置验证（`--validate-only`）、BASE 零偏移 smoke、H-GEO 单例路径 smoke 和 `git diff --check`。未运行三工况 H-GEO 校准、完整 Polar 或 Forward+ 图形测试。
