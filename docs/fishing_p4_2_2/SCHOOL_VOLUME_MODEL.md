# Fish Finder 鱼群空间代理

## 来源与边界

Authority 是唯一生态数据来源。单个 School 当前提供稳定 ID、鱼种 ID、世界锚点、人口和当前 `activity_depth_m`；它没有记录实际鱼群边界。Renderer 的可见鱼坐标只用于 P4.2.1 的调试对照，本次计算不读取实例位置、受惊散开半径，也不创建或移动鱼。

因此声呐使用的是**确定性推导代理**，不是 Authority 中测得的真实鱼群外沿：

- 水平半径：通常取 `school_wander_radius_m`；`coastal_benthic` 另取它与 `school_activity_radius_m` 的较大值。乘可调边界系数 `1.1`，并限制在 0.5–8 m。
- 垂直半厚度：取当前活动层对应的已有鱼种深度范围半宽；周期鱼种按当前活动深度选择表层/深层范围，近岸底栖鱼在近表层与优选范围中选择最近者。再限制在 0.4–1.5 m。
- 水层边界：每次扫描按当前局部海面、海图海底、0.6 m 海床净空和原有探测深度上限裁剪代理。输出深度仍以换能器为基准。

上述半径不是 `school_wander_radius_m + scatter_extension`，也不会随 Population 无上限增长。Population 只参与原有聚合回波规模/强度代理。

## 重叠近似

对代理中心相对换能器位置，将垂直有效区间分成 5 个固定 Simpson 样本（权重 1、4、2、4、1）。每个深度切片：

1. 按椭球截面得到鱼群水平半径：`R_school(z) = R * sqrt(1 - q²)`。
2. 按固定半锥角得到声束半径：`R_beam(z) = min(z * tan(10°), sqrt(220² - z²))`。
3. 用解析圆相交面积计算声束足迹覆盖率，再乘以基于最近径向距离与垂直归一化距离的局部密度权重。
4. 按 Simpson 权重与声束截面积聚合，得 `coverage_factor` 和 `overlap_factor`，二者限定在 0–1。

零交集返回 `outside_school_volume`；微弱交叠低于 0.0001 阈值不生成回波；边缘交叠输出 `partial_overlap`；高重叠且覆盖充分时输出 `school_volume_detected`。回波代表深度是可探测重叠切片按重叠权重求得的换能器下深度。没有采样随机数。

最终强度：

`group_strength = 1 - exp(-population / 8)`

`echo_strength = clamp(group_strength × overlap_factor × lerp(0.2, 1.0, range_score), 0, 1)`

`range_score` 沿用扫描距离衰减。空间代理导致的局部交叠调节强度；P2 概率没有参与，也没有改变。

## 候选与成本

查询半径使用 `max_slant_range_m + maximum_school_distribution_radius_m`，默认 228 m。它调用已有 Authority 空间索引；只有返回的有限候选才执行水深采样、5 个切片和圆面积求交。每个候选最多产生一个 School 诊断行和一个回波，不按样本数复制目标。P4.1 中记录的约 1510 个本地 School 不会被每帧全量遍历；扫描仍为 3 Hz。

## 解释限制

这是为了让极窄声束与活动鱼群空间尺度相匹配的聚合代理，不是鱼类个体位置概率模型，也不是水声物理仿真。真实鱼群可能并不均匀填满该体积；代理边界与密度权重是可校准的游戏化估计。浅层声束很窄时，即使 Renderer 可见鱼恰在船边，回波也可以是弱的部分重叠，而非整群强回波。

## 声呐演示预览

F3 预览完全由 `FishFinderDisplay` 创建独立的有限历史，不写入 `FishFinderSensor` 的扫描历史。每列只含一个 `debug_preview_school` 聚合回波且标记为 Debug，没有真实底部数据。预览不访问 Authority、P2 Encounter RNG 或海底采样。深度、峰值强度及规模改变时会重建预览列；停止后显示真实传感器历史。它只验证绘制映射和强弱节奏，不代表真实鱼群或传感器检测结果。
