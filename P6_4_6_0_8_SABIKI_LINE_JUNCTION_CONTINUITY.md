# P6.4.6.0.8 — 出水连接局部曲线修复与剩余问题

状态：P6.4.6.0.8 已完成并关闭；收尾采用方案 A，完成结论见文末“最终收纳收尾”。前面保留此前诊断及当时未完成项，供追溯。

## 已确认根因

HUD 的“鱼组入水·等待中”对应真实 WAITING，`manual_reeling=true`。手动收线没有独立 RETRIEVING 状态；后者表示最终收纳动画。

`_get_main_line_visual_state()` 的 airborne 否决了 forced_taut，空中时即使玩家收线、放线长度已经等于端点距离，仍返回 slack。共享主线路径随后按竿负荷推导的 slack_ratio 绘制 sin² 下垂和横摆。该形状没有可用的额外线长支撑，造成外部主线内部的曲率反转；顶环附近再连接方向不同的主干，使短距离弯折更加突出。问题至少包括 A（外线内部）和 B（连接方向差），不是仅靠整体姿态角度能描述。

sin² 两端导数为零本身不是错误。本轮没有替换 sin²、增加细分或改动串钩主干曲线。

## 修复

`boat_fishing_casting_system.gd` 在生成共享主线时加入表现层条件：手动收线或最终回收、非搏鱼、钓组实际全部出水（或已有 airborne 标记），且放线长度没有比端点距离多出 1 cm 以上时，关闭装饰性下垂及横摆。若存在真正的松线余量，保留原曲线。

这个条件只传入共同主线视觉路径，不改 taut 的其他消费者。直接改 taut 的试验曾改变 Sabiki 姿态负荷响应，已撤回。鱼竿、Solver、真实钩位、Authority、水下受载姿态和抛投逻辑保持原实现。

## 原基线 failures=1

断言：`Sabiki backbone remains aligned with all actual hook stations during retrieval at 30 FPS`，期望钩位到主干距离不超过 0.01 m。

旧 NDJSON 第 50 帧：WAITING，刚启动手动收线，elapsed=0.003863 s。根据其端点和原曲线重新构造的站点误差约 0.01885 m；旧记录坐标为字符串，估值受到舍入限制，不能当成高精度测量。原采样在 `process_frame` 恢复后读取 Mesh，同时重新计算新输入下的钩位，可能比较上一轮 Mesh 和当前几何。新增渲染完成后的 GPU 采样后，该断言通过，阈值仍为 0.01 m。

## 冻结帧与路径证据

测试工具在全部出水时暂停整个 SceneTree，而非只停 Casting，保留同一相机和几何，逐次切换组件可见性。保存完整画面、外线、主干、组合及紫色顶环标记；恢复后继续运行。每次冻结同时写入 Mesh 中心线和状态。

- [修复前完整冻结帧](reports/p6_4_6_0_8/before/sabiki_rig_30_retrieve_fully_airborne_frozen_full.png)
- [修复前外线](reports/p6_4_6_0_8/before/sabiki_rig_30_retrieve_fully_airborne_mainline_only.png)
- [修复前末端钓组](reports/p6_4_6_0_8/before/sabiki_rig_30_retrieve_fully_airborne_terminal_rig_only.png)
- [修复前组合](reports/p6_4_6_0_8/before/sabiki_rig_30_retrieve_fully_airborne_mainline_and_backbone.png)
- [修复前顶环标记](reports/p6_4_6_0_8/before/sabiki_rig_30_retrieve_fully_airborne_top_eye_marked.png)
- [修复后完整冻结帧](reports/p6_4_6_0_8/after/sabiki_rig_30_retrieve_fully_airborne_frozen_full.png)
- [修复后外线](reports/p6_4_6_0_8/after/sabiki_rig_30_retrieve_fully_airborne_mainline_only.png)
- [修复后末端钓组](reports/p6_4_6_0_8/after/sabiki_rig_30_retrieve_fully_airborne_terminal_rig_only.png)
- [修复后组合](reports/p6_4_6_0_8/after/sabiki_rig_30_retrieve_fully_airborne_mainline_and_backbone.png)
- [修复后顶环标记](reports/p6_4_6_0_8/after/sabiki_rig_30_retrieve_fully_airborne_top_eye_marked.png)

同一次冻结的各组件视图状态相同；前后两个运行的冻结时机并不完全相同，不能作为逐像素相同状态比较。

原始路径、竿尖、顶环、铅坠、五钩位置以及局部分析分别保存在 [before/frozen_geometry.json](reports/p6_4_6_0_8/before/frozen_geometry.json) 和 [after/frozen_geometry.json](reports/p6_4_6_0_8/after/frozen_geometry.json)。其中包含外线最后五点及主干最初五点。

| 数据 | 修复前冻结帧 | 修复后冻结帧 |
|---|---:|---:|
| 状态 | WAITING / 手动收线 | WAITING / 手动收线 |
| 放线长度 | 0.895729 m | 0.797601 m |
| 实际端点距离 | 0.895877 m | 0.797918 m |
| 原逻辑 slack_ratio | 0.433837 | 0.631431 |
| 空中姿态权重 | 0.92 | 0.92 |
| Mesh 连接方向差 | 5.8259° | 7.8534° |

修复后原 slack 状态仍可供既有姿态系统使用，但没有余线的外部 Mesh 不再绘制额外下垂。连接方向差没有被强制压到零，也没有用它作为成功标准。

旧 NDJSON 的 Vector3 默认序列化为字符串，在约 13 km 世界坐标处仅保留约厘米级显示精度。因此对旧字符串路径计算得到的单段转角（约 5–10°）包含明显舍入误差，不能诚实地当作局部曲率改善量。测试已补充完整数值坐标数组，后续捕获可用于精确局部转角分析；本轮旧帧无法恢复已丢失的精度。

## 测试与实际画面

- 真实 main.tscn、Metal Forward+、M2 Pro，GPU 目标上限 30 FPS，实际约 5.5–14 FPS。前后均采集抛投、全部出水、最终收纳和 Single Jig 对照。
- 一次修复后 GPU 完整运行 failures=0；最终更严格的渲染后采样运行仍有 1 条覆盖失败：`Sabiki produces measurable high-weight airborne pose samples at 30 FPS`，实际稳定飞行样本数 0，期望至少 1。该次抛投实际约 5.53 FPS，短飞行阶段未被采到，不能宣称此次 GPU 抛投覆盖通过，也未放宽断言。
- P6.3.1 Headless：failures=0。
- P6.3.2 Headless：failures=0。
- 运行时几何 Headless（30/60 上限）：补充数值日志后的最终运行 failures=0，包含新增无余线出水主线不绘制 S 形下垂断言。
- GPU/Headless 退出时仍有 Shader/RID 泄漏提示。
- git diff --check：通过。

## 剩余问题与验收结论

全部出水手动收线时，无余线却绘制 S 形下垂的错误已实施最小修复。但 [最终收纳截图](reports/p6_4_6_0_8/after/sabiki_rig_30_retrieve_final_retrieval.png) 仍有可见连接转角。本轮没有把它解释成“短线可忽略”，也没有声称所有可见折角已经消失。

还缺少：对同一故障冻结状态的高精度修复前后重放、最终收纳转角的单独根因修复，以及补足低 FPS 未采到的抛投稳定阶段覆盖。因此 P6.4.6.0.8 整体尚未完成。

修改文件为 scripts/boat_fishing_casting_system.gd、tests/test_p6_4_6_0_3_runtime_line_geometry.gd、本报告和 reports/p6_4_6_0_8 证据目录。

## 最终收纳收尾（本轮最终结论）

玩家已接受此前出水收线的轻微折角，本轮未继续改动该阶段、主线松弛模型、主干曲线或鱼竿。

### 原因与方案 A

`_get_sabiki_airborne_pose()` 原先在 RETRIEVING 内将空中伸展权重乘以 `1 - smoothstep(0, 0.72, elapsed)`，在最后可见帧恢复自然竖直。与此同时，`_update_retrieve_animation()` 每帧通过当前连接偏移重算回收目标。姿态渐退改变了顶环偏移和运动目标，因此在钓组隐藏之前出现一次明显转向。

本轮只删除 RETRIEVING 中这层姿态渐退，保留原有伸展计算，直到现有 progress>=1 的回收完成分支统一隐藏外线、顶环及整个 Sabiki 钓组。没有提前按 paid_line 隐藏，也没有新增插值、曲线或状态机。`stow_progress` 仅保留为回收进度诊断，不再驱动方向渐退。

无需新增姿态复位字段：姿态由当前 CASTING/WAITING/RETRIEVING 和现有运动实时计算；完成分支仍清零线长、速度、负荷和瞄准状态，下一次正常抛投重新计算姿态。

### 真实 GPU 检查

Metal Forward+、M2 Pro、实际 main.tscn 和正常 HUD。沿用相同测试相机与船位，分别采集原有版本与最终版本。GPU 实际约 7–11 FPS，30 FPS 为上限设置。

- [修复前最终收纳](after/sabiki_rig_30_retrieve_final_retrieval.png)
- [修复后最终收纳](final_stow/sabiki_rig_30_retrieve_final_retrieval.png)
- [原有出水阶段对照](final_stow/sabiki_fully_airborne_retrieval.png)
- [收纳完成、钓组与外线隐藏](final_stow/sabiki_recovered.png)
- [再次正常抛投、可见性恢复](final_stow/sabiki_recast.png)
- [Single Jig 最终回收对照](final_stow/single_jig_30_retrieve_final_retrieval.png)
- [确定性飞行阶段 GPU 截图](final_stow/sabiki_fixed_step_flight.png)
- [本轮 GPU 路径及状态数据](final_stow/runtime.ndjson)

修复后最终收纳帧保持伸展，没有原来那次突然转回竖直的明显转折。完成后无悬空外线或残留钩组；第二次抛投能正常显示五钩及铅坠。逐帧记录及截图检查未发现提前隐藏后又重现的闪烁。

### 补足飞行覆盖

在真实 begin_charge/release_charge 后，测试暂停场景，用固定 1/60 s 步长调用正式 `_update_cast_animation()` 和正式 Mesh 更新，到高伸展飞行状态采集一次，然后恢复正常 GPU 运行。没有改变正式飞行参数、降低角度要求或删除覆盖断言。

确定性样本：alignment_weight=0.94，实际 Mesh 连接方向差=9.4966°，固定模拟步长=0.0166667 s。该样本补足此前 5.5 FPS 漏采的短暂飞行窗口；它不证明 GPU 实际达到 60 FPS。原有实际播放仍在低帧率下检查。

### 验证与边界

- 最终 GPU 运行时几何定向测试：failures=0；包括顶环/主线连接、五钩站点、完成隐藏及第二次抛投显示。
- P6.3.1 Single Jig：failures=0，包含鱼嘴锚定、搏鱼、收获和断线清理。
- P6.3.2 Sabiki：failures=0，包含多钩鱼嘴锚定、批次结算和活动清理。
- Headless 运行时几何（30/60 FPS 上限，两种钓组）：最终 failures=0，保留原阈值；完成隐藏和再次抛投断言通过。
- git diff --check：通过。

仍保留 Godot 退出时的 Shader/RID 泄漏提示，本轮没有扩展到资源释放审计。玩家已接受的出水轻微折角保持原样；最终收纳采用方案 A，不再开发新的鱼线几何机制。

最终结论：GPU 视觉检查与上述必要回归已通过，P6.4.6.0.8 可以关闭。停止修改鱼线系统，不进入下一阶段。
