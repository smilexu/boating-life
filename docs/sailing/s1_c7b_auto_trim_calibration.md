# S1-C7b：双帆自动操帆曲线优化与航向配平

## 结论

已把 C7a 的固定 AWA 插值点移入 SailboatLab 船型 Resource，并用相同目标 TWA、静水条件和真实船舵控制进行了 AUTO 与手动组合对比。8 m/s 下，AUTO 在 90°、120°、150°均达到稳态，分别比 C6 手动参考快 1.26%、3.44%、18.73%；左右舷结果镜像一致。60°仍是 `control_limited`，因此不作为稳态极曲线点，也没有为它编造推荐解。

物理公式和船体参数没有调整。曲线只决定两张帆的目标角；实际角仍通过原有限速和限位跟随。

## 方法

- 复用了 C5e/C6 的 SailboatLab 刚体测试和诊断专用航向控制器。它通过真实船舵维持目标 TWA，没有锁定刚体旋转、覆写速度或施加额外航向力矩。
- 测试统一采用静水、零海流、固定风场种子、60 Hz 物理步、同一船型 Resource、同一起始状态。长测运行 120 秒，使用相邻的 30 秒窗口检查稳定性。
- 先对 8 m/s 下 60°/90°/120°/150°各做 3×3、20 秒局部候选筛选；再对候选进行 120 秒验证。150°候选在初次扫描边界，因此另做 3 个延伸验证。
- 补充测量 5 m/s 和 12 m/s 下 90°/120°。最终左右舷镜像覆盖 8 m/s 的 ±60°/±90°/±120°/±150°。
- 稳态数据是 120 秒末段统计。`control_limited` 结果保留为诊断数据，但不能当作稳定可控航速。

## 8 m/s 受控对比

速度为末段平均值；纵向速度是船体局部 -Z 方向分量。舵角为末段平均实际值。横倾和侧滑为末段绝对值平均。

先看 C7a 原曲线在同一测试器内与 C6 手动参考的差异：

| 目标 TWA | C7a AUTO | C6 手动参考 | 差异 | C7a 状态 |
|---:|---:|---:|---:|---|
| 60° | 1.773 kn | 1.865 kn | -4.94% | control_limited |
| 90° | 2.815 kn | 2.981 kn | -5.57% | steady |
| 120° | 2.921 kn | 3.261 kn | -10.42% | steady |
| 150° | 2.369 kn | 2.274 kn | +4.18% | steady |

曲线调整后，8 m/s AUTO 相对原 AUTO 在上述角度分别变化约 +0.17%、+7.24%、+15.48%、+13.96%。60°前后均为 `control_limited`，该速度差不代表可控的稳态性能改善。

| 目标 TWA | 校准 AUTO 主帆/Jib | AUTO SOG | C6 手动参考 | 差异 | AUTO 纵向速度 | 平均舵角 | 横倾 | 侧滑 | 状态 |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| +60° | -30.3° / -25.3° | 1.776 kn | 1.865 kn | -4.79% | 0.879 m/s | +33.63° | 6.29° | 15.62° | control_limited |
| -60° | +30.3° / +25.3° | 1.776 kn | 1.865 kn | -4.79% | 0.879 m/s | -33.63° | 6.29° | 15.62° | control_limited |
| +90° | -59.9° / -54.9° | 3.019 kn | 2.981 kn | +1.26% | 1.549 m/s | +6.50° | 4.73° | 4.04° | steady |
| -90° | +59.9° / +54.9° | 3.019 kn | 2.981 kn | +1.26% | 1.549 m/s | -6.50° | 4.73° | 4.04° | steady |
| +120° | -79.9° / -70.0° | 3.373 kn | 3.261 kn | +3.44% | 1.735 m/s | -0.31° | 2.16° | 1.13° | steady |
| -120° | +79.9° / +70.0° | 3.373 kn | 3.261 kn | +3.44% | 1.735 m/s | +0.31° | 2.16° | 1.13° | steady |
| +150° | -79.9° / -70.0° | 2.700 kn | 2.274 kn | +18.73% | 1.389 m/s | -4.24° | 0.30° | 0.32° | steady |
| -150° | +79.9° / +70.0° | 2.700 kn | 2.274 kn | +18.73% | 1.389 m/s | +4.24° | 0.30° | 0.32° | steady |

TWA 60°的平均舵角已经接近 ±35°限位，平均航向误差约 6.73°，侧滑约 15.62°。AUTO 比手动参考略慢，且两者都未满足受控稳态要求。仅凭这次帆角扫描不足以解决近迎风配平；当前曲线保留 C7a 的 60°及以内控制点。

### 其他风速

| TWS | TWA | AUTO | C6 手动参考 | 差异 | AUTO 平均舵角 | AUTO 横倾 | 状态 |
|---:|---:|---:|---:|---:|---:|---:|---|
| 5 m/s | 90° | 1.572 kn | 1.545 kn | +1.73% | +9.64° | 1.76° | steady |
| 5 m/s | 120° | 1.775 kn | 1.698 kn | +4.51% | -0.37° | 0.81° | steady |
| 12 m/s | 90° | 4.984 kn | 4.911 kn | +1.49% | +3.90° | 11.07° | steady |
| 12 m/s | 120° | 5.578 kn | 5.429 kn | +2.73% | -0.82° | 5.01° | steady |

12 m/s、90°时 AUTO 横倾比手动参考高约 0.41°，其余对照的横倾略低。此处没有加入减帆或横倾修正逻辑。

## 曲线校准

控制器仍以 **|AWA|** 作为输入，按曲线线性插值；左右舷根据已有符号规则镜像输出。控制点取自长测稳态的实际 AWA，而不是把 TWA 网格直接当作 AWA。

| |AWA| | 主帆展开幅度 | Jib 展开幅度 | 依据 |
|---:|---:|---:|---|
| 0° | 10° | 10° | 保留 C7a |
| 30° | 10° | 10° | 保留 C7a |
| 45° | 20° | 15° | 保留 C7a |
| 60° | 30° | 25° | 保留 C7a；近迎风仍未通过可控性筛选 |
| 80.2° | 60° | 55° | 8 m/s、TWA 90°候选长测 |
| 108.1° | 79.9° | 70° | 8 m/s、TWA 120°候选长测 |
| 143.1° | 79.9° | 70° | 8 m/s、TWA 150°延伸长测 |
| 180° | 79.9° | 70° | 在已验证的最大限位附近平滑延续 |

主帆 79.9°低于 Resource 80°机械上限；Jib 70°低于其 Resource 限位。AUTO/MANUAL 切换、手动调整帆角时退出 AUTO、A/D 掌舵不退出 AUTO、禁用 Jib 时只控制主帆等 C7a 行为保留。

20 秒筛选中，TWA 90°的主要提升来自 Jib 从参考 45°调整至约 55°；120°选择较大展开角；150°初筛的最佳主帆落在候选边界，延伸的 120 秒测试支持主帆约 80°、Jib 70°。这解释了为何报告采用较大的 150°展开角，而不是把短测边界结果直接当作最终结论。

## 航向、配平和自由航行

- 90°稳态样本中主帆、Jib、龙骨、舵偏航力矩均记录在 `yaw_balance_comparison.csv`。AUTO 相比原手动参考的平均舵角从约 6.91°降到 6.50°，横倾从 4.77°降到 4.73°，侧滑从 4.21°降到 4.04°。
- 120°的 AUTO 舵角略高于手动参考（0.31° 对 0.09°），但侧滑和横倾更低；150°的 AUTO 航速更高，平均舵角约 4.24°，仍远离舵限位。
- 左右舷 90°/120°/150°镜像结果的 SOG 差不超过 0.000001 kn，角度和横向量符号相反，横倾幅值对应一致。
- 自由航向 8 m/s 测试运行 120 秒：C7b 在 90–120 秒窗口平均 HDG 19.53°、SOG 1.567 kn、纵向速度 0.802 m/s，窗口间 SOG 变化约 0.0000 kn；C7a 历史末值为 HDG 29.76°、SOG 1.276 kn。两者自由航向，且统计方式一个是窗口均值、一个是历史末值，只作行为对照，不作为固定 TWA 极曲线提升率。
- 持续左满舵回归中，AUTO 仍允许手动掌舵；船越过 HDG 000°，在 80 秒约到 HDG 353.58°。随后满舵下转向趋于停滞，说明系统仍不是自动航向控制器，AUTO 操帆没有消除帆/龙骨/舵之间的自然力矩平衡。此表现与 C7a 基线相近。

## 性能与查询预算

Headless 计时中，8 m/s 下对应四个正舷核心风角的 AUTO 计算时间中位数约为 13.27 μs 平均、22 μs P95；C7a 对应基线为约 14.72 μs、26.5 μs。物理代码段计时中位数分别约 121.5/194.5 μs 与 144.5/231.5 μs。这里是微秒级代码计时样本，测试场景和进程噪声会影响结果，不据此宣称稳定的整机性能提升。

查询计数没有增加：静水受控测试每物理步 1 次 WindField、0 次 WaveSampler；动态海浪 guard 每步 1 次 WindField、4 次 WaveSampler。Auto 只对缓存的风数据做曲线插值。未进行图形 GPU 帧时间、Forward+ 画面或 M2 专项验收。

## 修改与验证

本阶段直接修改/新增：

- `resources/sailing/sailboat_lab_profile.gd`、`resources/sailing/sailboat_lab_profile.tres`：添加船型可配置的主帆/Jib AUTO 曲线。
- `scripts/sailboat_lab_body.gd`：启动时从 Profile 配置 AutoSailTrim 曲线。
- `scripts/sailboat_auto_sail_trim.gd`：保留 C7a 控制器默认曲线作为未配置时的回退。
- `tests/test_sailboat_auto_sail_trim.gd`：新增校准曲线和镜像断言。
- `tests/run_sailboat_s1_c7b_trim_calibration.gd`：筛选、120 秒验证、自由航行、舵回归、查询预算与 CSV 输出。
- `docs/sailing/c7b_data/`：保留原始曲线、校准曲线和诊断数据。

没有修改帆力/水动力公式、Resource 中物理系数、主帆/Jib 面积与受力中心、质量、阻尼、WaveSampler、WindField 或 Main 场景。

已运行的自动化检查：

- `test_sailboat_auto_sail_trim.gd`：57 项通过。
- 气动 321、Jib 46、水动力 60、浮力 87、导航仪表 46、Polar math 12、阻尼策略 17、WindField 23、SailboatLab 快捷键 14 项通过。
- 浅水波浪约束 80 项通过；测试退出时出现 DummyShader RID 泄漏警告，来自 headless 渲染测试路径，不能据此判断为本次 AUTO 修改导致。
- S1-C7b 的 `screen`、`calibrate`、`refine`、`verify`、`regression` 与最后的 `smoke` 阶段均通过；smoke 最近一次运行 2 组、约 30.17 秒。
- `git diff --check` 通过。

示例运行命令：

```sh
godot --headless --path . --script res://tests/run_sailboat_s1_c7b_trim_calibration.gd -- --phase=screen
godot --headless --path . --script res://tests/run_sailboat_s1_c7b_trim_calibration.gd -- --phase=calibrate
godot --headless --path . --script res://tests/run_sailboat_s1_c7b_trim_calibration.gd -- --phase=refine
godot --headless --path . --script res://tests/run_sailboat_s1_c7b_trim_calibration.gd -- --phase=verify
godot --headless --path . --script res://tests/run_sailboat_s1_c7b_trim_calibration.gd -- --phase=regression
```

## 数据文件与限制

- [controlled_auto_vs_manual.csv](c7b_data/controlled_auto_vs_manual.csv)：末段稳态统计及历史基线、手动参考、筛选候选和校准 AUTO；包含 SOG、船体纵横速度、帆力、偏航力矩、舵角、横倾、侧滑和状态。
- [trim_candidate_screening.csv](c7b_data/trim_candidate_screening.csv)：36 组 20 秒局部筛选，字段为风况、帆角、评分、状态、速度和配平诊断；只用于筛选，不是稳态成绩。
- [candidate_long_validation.csv](c7b_data/candidate_long_validation.csv)：7 组 120 秒候选验证与 150°延伸测试。
- [calibrated_auto_trim_curve.csv](c7b_data/calibrated_auto_trim_curve.csv) 与 [c7a_original_trim_curve.csv](c7b_data/c7a_original_trim_curve.csv)：可配置曲线与 C7a 原始点。
- [yaw_balance_comparison.csv](c7b_data/yaw_balance_comparison.csv)：主帆、Jib、龙骨和舵偏航力矩分项；不代表 Godot 内部全部合力矩。
- [free_sailing_before_after.csv](c7b_data/free_sailing_before_after.csv)：自由航向总结及 1 Hz 时间序列。
- [auto_rudder_regression.csv](c7b_data/auto_rudder_regression.csv)：C7a/C7b 左满舵时序。
- [auto_trim_performance_comparison.csv](c7b_data/auto_trim_performance_comparison.csv)：Headless 计时和每步查询计数。

已知限制：近迎风 60°工况仍需较大平均舵角并被分类为 `control_limited`；本阶段没有航向/航线自动控制。曲线锚点只在有限风速和受控角度测试，不代表其他船型或所有风况最优；150°性能来自当前简化双帆模型。最终手感和 Forward+ 视觉、M2 GPU 性能仍需人工验收。

**Main 接入判断：** Resource 化和受控测试已证明该曲线可在 SailboatLab 中运行，具备后续接入试验的代码基础；但在完成 60°近迎风控制问题的定位，以及 macOS/Windows Forward+ 人工验收之前，不建议把它作为 Main 的默认正式操帆配置。本轮没有进行 Main 接入。

完成后停止在 SailboatLab AUTO 曲线校准阶段；未接入 Main，未实现自动掌舵、自动巡航或换舷 AI。
