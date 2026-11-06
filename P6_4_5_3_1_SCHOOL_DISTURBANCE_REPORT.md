# P6.4.5.3.1 — 鱼群惊扰模型与 Authority 接入报告

## 1. 结果摘要

已将船只惊扰从渲染器按水平距离单独判断，改为 `FishLocalAuthority` 对每个鱼群持有连续惊扰值与状态。船只靠近水面鱼群时惊扰较强；同样船速下，鱼群越深，惊扰越弱。鱼群只有在权威状态进入 `FLEEING` 后才播放逃散表现。`SCHOOL_TARGETED` 读取权威咬钩意愿系数；`AMBIENT_ENCOUNTER`、拖钓、人口和搏鱼物理不使用这项修正。

核心实现位于 `FishSchoolDisturbanceModel`、`FishResourceManager._update_authoritative_disturbance()` 与 `FishLocalAuthority.update_school_disturbance()`（见 `scripts/fish_school_disturbance_model.gd:8`、`scripts/fish_resource_manager.gd:116`、`scripts/fish_local_authority.gd:133`）。

## 2. 原有惊扰逻辑与根因

原渲染器为岸边鱼、表层鱼和其他鱼群各自计算了本地威胁值。主要输入是船或其他威胁源到可视个体的水平距离及运动方向；这些判断不读取鱼群相对船底的深度，也不区分发动机工作与停机漂流。结果是船经过深水鱼群正上方也可能让渲染器直接进入警觉或逃散状态。

本轮移除了渲染器的水平距离威胁评分、表层威胁评分和本地威胁源发现接口。可视鱼群现在读取 Authority 快照里的 `disturbance_state` 与 `disturbance_level`，再决定显示警觉、散开或恢复（`scripts/fish_school_renderer.gd:832`、`scripts/fish_school_renderer.gd:849`、`scripts/fish_school_renderer.gd:900`）。逃散方向仍可参考船的方位，但它只在 Authority 已经给出 `ALERT`/`FLEEING` 后用于选择视觉朝向；方向计算不再触发惊扰。

渲染器保留短暂的本地 `recovering` 动画阶段，作为表现过渡。该阶段只控制散开后的回群动画，不维护第二份惊扰强度，也不能触发新的警觉或逃散。

## 3. 三维模型与配置

惊扰目标值为：

```text
H = exp(-pow(max(horizontal_distance_m, 0) / horizontal_falloff_m, 2))
V = exp(-max(vertical_below_hull_m, 0) / vertical_falloff_m)
target = clamp(H * V * vessel_disturbance * species_sensitivity, 0, 1)
```

默认水平衰减尺度为 12 m，垂直衰减尺度为 3.5 m。配置集中在 `FishResourceManager` Inspector（`scripts/fish_resource_manager.gd:21`），计算集中在 `scripts/fish_school_disturbance_model.gd:63`。

Authority 使用鱼群中心到船的 XZ 水平距离。鱼群中心水下位置由该处动态海面高度减去 Authority 的有效活动水深得到。船底高度采用船位置附近的动态海面高度减去 `BoatController.get_current_draft_m()`。缺少有效吃水数据时使用集中回退值 0.8 m（`scripts/fish_resource_manager.gd:119`、`scripts/fish_resource_manager.gd:160`、`scripts/fish_local_authority.gd:133`）。因此垂直距离是“鱼群代表中心在船底以下多少米”，不是鱼群到海面的深度。

这里用当前吃水近似船底平面，没有查询实际船壳水下网格；各船的首尾、龙骨形状和横倾差异尚未纳入。这是明确的游戏标定近似，不是水下声学测量模型。

## 4. 船只扰动与鱼种敏感度

船只输入来自 `BoatController`：`has_engine()`、`get_engine_audio_state()` 的运行状态和油门需求，以及 `speed_mps`。动力船怠速及低速、巡航、高速区间分段映射到扰动强度；油门需求可提高动力扰动。发动机关闭时只按速度从停机/漂流基线插值，不把帆船或熄火船的航速当成发动机噪声（`scripts/fish_school_disturbance_model.gd:8`）。缺少发动机状态 API 时，采用相同的保守“仅按运动速度”回退，不猜测船型。

初始参数均可在 `FishResourceManager` 调整（`scripts/fish_resource_manager.gd:35`）：

| 船只状态 | 扰动值 |
|---|---:|
| 发动机关闭、静止（≤0.08 m/s） | 0.08 |
| 发动机关闭、漂流（>0.08 m/s） | 0.12 起，至 6 m/s 线性升到 0.50 |
| 发动机运行、怠速（≤0.25 m/s） | 0.30 起，可由油门需求提高 |
| 动力低速（0.25–1.5 m/s） | 0.50 |
| 巡航（1.5–5.5 m/s） | 0.50 → 0.80 线性插值 |
| 高速（5.5–8 m/s） | 0.80 → 1.00 线性插值；之后保持 1.00 |

鱼种敏感度加入现有 `FishSpeciesProfile`。Herring=1.00、Sea Trout=1.20、Needlefish=0.85，其余默认 1.00；没有改动其他生态属性（`scripts/fish_species_profile.gd:35` 与对应三个 `.tres`）。最终目标值仍限制到 `[0,1]`。

本轮未加入加速度或急转附加量：当前没有在这条调用链中确认到适合本功能的可靠统一指标。

## 5. Authority 状态、滞回与生命周期

每个 `FishSchoolState` 现保存 `disturbance_level`、`disturbance_target`、`disturbance_state`、持续强扰动时间、诊断距离、船只扰动和咬钩意愿。快照 schema 升至 4，同时继续接受 schema 3；旧快照以 CALM/默认值恢复。坐标非法时拒绝恢复，诊断数值非法时回退到安全默认值（`scripts/fish_school_state.gd:32`、`scripts/fish_school_state.gd:43`、`scripts/fish_school_state.gd:87`）。

当前状态参数：

| 参数 | 默认值 |
|---|---:|
| 惊扰上升时间常数 | 3.0 s |
| 惊扰下降时间常数 | 12.0 s |
| CALM → ALERT | 0.20 |
| ALERT → CALM | 0.12 |
| FLEEING 进入值 | 0.65，且目标值需持续达到该值 1.5 s |
| FLEEING 退出值 | 0.45 |

连续值按 `alpha = 1 - exp(-dt / tau)` 更新。强扰动计时使用 Authority 当前收到的帧 delta；低于 FLEEING 目标门槛时清零。状态转换具有独立的进入/退出阈值，防止边界抖动（`scripts/fish_school_disturbance_model.gd:77`）。

`FishResourceManager` 每帧向 Authority 提供附近 48 m 的鱼群快照和仍处于恢复中的鱼群；每群的水面高度由动态海面采样。局部 Authority 持有状态，状态转换才递增 revision；鱼群恢复到 CALM 且接近零后从追踪集合移除。鱼群人口、位置和生成规则没有因惊扰改动（`scripts/fish_resource_manager.gd:100`、`scripts/fish_resource_manager.gd:147`、`scripts/fish_local_authority.gd:120`、`scripts/fish_local_authority.gd:188`）。

惊扰值随学校快照序列化；没有新增离线演算。场景恢复后由当前船只位置和后续帧 delta 继续更新。若未来使用服务器 Authority，适配器还需实现同一更新与快照接口；当前项目安装的是本地 Authority。

## 6. SCHOOL_TARGETED 咬钩意愿

意愿倍率为 CALM=1.00、ALERT=0.80、FLEEING=0.25，在 `FishLocalAuthority` 更新并随学校快照暴露。定向候选只读取并携带该倍率；唯一实际应用点是定向反应时间的推进速度：`remaining_seconds -= delta_real_seconds * willingness`（`scripts/fishing_encounter_system.gd:428`、`scripts/fishing_encounter_system.gd:714`）。因此 ALERT 下既有反应时间约增加 25%，FLEEING 下约增加到四倍；它不会让合法鱼群被绝对禁止咬钩。

该倍率只作用于 `SCHOOL_TARGETED` 反应过程一次。候选合法性、深度、水饵动作、基础事件规则不变；AMBIENT Hazard 和拖钓不读取此系数。已开始的搏鱼会话不再受后续鱼群状态改变影响。

## 7. 五个指定场景的定量结果

测试使用 Herring（敏感度 1.0）、水平距离 0 m、船底吃水近似 0.8 m、油门需求 0；从 CALM/level=0 开始，以 1/60 s 步进模拟 5 s。表中“深度”是鱼群中心距海面深度；`V=exp(-(depth-0.8)/3.5)`，负值按 0 计。低速动力船取 1 m/s；高速动力船取 9 m/s；停机漂流取 0.4 m/s。

| 场景 | 水深 | 船只扰动 | 惊扰目标 | 5 s 惊扰值 | 5 s 状态 | 咬钩意愿 |
|---|---:|---:|---:|---:|---|---:|
| A. 慢速动力船 | 1 m | 0.500 | 0.4722 | 0.3830 | ALERT | 0.80 |
| B. 慢速动力船 | 3 m | 0.500 | 0.2667 | 0.2163 | ALERT | 0.80 |
| C. 慢速动力船 | 8 m | 0.500 | 0.0639 | 0.0518 | CALM | 1.00 |
| D. 高速动力船 | 1 m | 1.000 | 0.9445 | 0.7661 | FLEEING | 0.25 |
| E. 发动机关闭、漂流 | 3 m | 0.1453 | 0.0775 | 0.0629 | CALM | 1.00 |

数值由 `tests/test_p6_4_5_3_1_school_disturbance.gd` 直接运行模型得到。水平距离 0 不会跳过惊扰累积或 1.5 s 强扰动要求；水深 8 m 的低速通过不会进入 FLEEING。

## 8. F3 诊断与修改文件

Fishing F3 的 Authority 惊扰区新增 School ID、Species、水平距离、船底以下深度、船只扰动、目标值、累积值、状态和咬钩意愿；无候选鱼群时显示明确的“无附近目标”文本。状态和文本提供英文、简体中文翻译（`scripts/fishing_debug_panel.gd:1192`、`resources/translations/fish_species.csv:897`）。

修改文件：

- 新增 `scripts/fish_school_disturbance_model.gd` 及 Godot UID。
- 更新 `scripts/fish_resource_manager.gd`、`scripts/fish_local_authority.gd`、`scripts/fish_authority_adapter.gd`、`scripts/fish_school_state.gd`。
- 更新 `scripts/fish_school_renderer.gd`、`scripts/fish_species_profile.gd`、`scripts/fishing_encounter_system.gd`、`scripts/fishing_debug_panel.gd`。
- 更新 Herring、Sea Trout、Needlefish 资源及鱼种翻译文件。
- 更新 `tests/test_fish_resources.gd` 与 `tests/test_p6_4_5_1_boat_fishing_bite_rework.gd`，新增 `tests/test_p6_4_5_3_1_school_disturbance.gd` 及 Godot UID。

## 9. 定向测试结果

以下 headless 检查均以 Godot 4.7.2 执行：

- `tests/test_p6_4_5_3_1_school_disturbance.gd`：`failures=0`。覆盖指定 A–E 数值、水平/垂直单调衰减、短脉冲不直接逃散、30/60 FPS 连续更新、恢复滞回、船只状态映射、Authority 快照、非法坐标/数值回退及中英文翻译键。
- `tests/test_fish_resources.gd`：`failures=0`。覆盖真实 Authority 快照到渲染行为的关联；船在鱼群正上方但 Authority 为 CALM 时不逃散，Authority 为 FLEEING 才散开。
- `tests/test_p6_4_5_1_boat_fishing_bite_rework.gd`：`failures=0`。覆盖 SCHOOL_TARGETED 与 AMBIENT 的原有流程及定向意愿系数。
- `tests/test_fishing_p3_2.gd`：`failures=0`。拖钓/P3.2 演出回归保持通过。
- `git diff --check`：通过。

Headless 运行环境显示无 rendering device；资源测试退出时还有一个现存的 DummyShader RID 泄漏提示。该提示不影响上述断言结果，但本轮没有做 GPU 画面验收。

## 10. 未完成的视觉验收与限制

- 尚未在 GPU 场景中验证鱼群从船下经过、不同吃水船型、横倾/俯仰时的实际惊扰观感；P6.4.5.3.2 仍需负责视觉逃散速度和散开幅度调整。
- 船底采用动态水面高度减当前吃水的平面近似，不对应实际船壳轮廓。
- 船扰动目前使用 `speed_mps`、发动机运行和油门需求；未加入加速度、急转或单独的螺旋桨/发动机声学模型。
- 渲染器按其现有低频行为 tick 读取 Authority 状态；逻辑状态是 Authority 的，显示会存在一个视觉更新间隔的延迟。
- 该公式属于可调游戏模型，参数尚未经过真实玩家平衡测试。
