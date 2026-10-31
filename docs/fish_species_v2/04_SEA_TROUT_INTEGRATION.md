# P1.3 海鳟接入

**状态：**PASS  
**阶段目标：**从 `assets/fishes/seetrout.glb` 建立 `sea_trout` Profile，并接入既有 deterministic authority、鱼群 renderer/MultiMesh、F4 和测试路径。  
**预计修改：**`resources/fish_species/sea_trout.tres`、`scripts/fish_resource_manager.gd`、`scripts/fish_local_authority.gd`、`scripts/fish_school_renderer.gd`、`scripts/fish_resource_map.gd`、`scripts/boat_hud.gd`、鱼类自动测试及模型导入 sidecar。  
**验收：**真实 GLB 可加载且当前 renderer 所需 mesh/surface/material 有效；鱼群受海图水深约束；深层保留权威逻辑状态；F4 可查；不会改变其他鱼的生态数量；MultiMesh 仍为统一渲染路径。

## 实施前注意

- 先确认 `sea_trout.tres` 的实际 spawn 权重和导入模型，不根据之前的会话摘要推断磁盘状态。
- 海鳟仅模拟海水生长阶段，不添加河流或繁殖逻辑。
- 生成权重为可调游戏参数；按本地完整水深数据区域观察新布局后再定初始稀有度。

## 阶段完成记录

### 2026-10-30 完成记录

- 加入 `resources/fish_species/sea_trout.tres`，稳定 ID `sea_trout`、学名 *Salmo trutta*、English/简中 key。只模拟海水生长阶段，不加河流、繁殖或淡水行为。
- Profile 初值：海图水深 2–25 m、偏好 3–12 m；活动层 surface 0.5–5 m / deep 6.5–12 m；人口每校 1–3；速度 0.4–1.0 m/s；`spawn_chance=0.015`；视觉和逻辑状态都启用。适合拖钓与拟饵 tag 仅登记在配置中，当前没有 fishing consumer。
- 注册到 `FishResourceManager` 的默认 profile 集合，走 `FishLocalAuthority` profile 驱动的生成、水深适宜度、活动循环、学校状态与快照；渲染/F4 使用现有 Renderer 和 MultiMesh，无海鳟专用模拟器。
- 首次导入由 Godot 生成 GLB `.import` sidecar 和引用的纹理导入资源。检查结果：GLB 实例尺寸 AABB 约 `(1.1681, 0.1386, 0.3335) m`，一个 `MeshInstance3D`、一个 Mesh surface，首 surface 绑定 Base Color 纹理；与当前只消费首 Mesh/surface 的 MultiMesh adapter 一致，没有发现会丢掉的额外身体 mesh 或材质 surface。
- 真实 DTM 与确定性 seed 下海鳟生成 38 个学校，占全部 1510 个学校约 2.5%，低于鲱鱼的 461 个学校；模型、profile、深浅水逻辑/视觉层、F4 数据均通过 Headless 检查。
- Sea Trout 物理模型/渲染没有进行 Forward+ 人工目视验收：**NOT RUN**。结构兼容验证不等于材质/朝向画面验收。

**P1.3 状态：PASS。**

### 2026-10-30 朝向复核

- 以海鳟的嘴/吻部和尾鳍为识别点，对 `seetrout.glb` 做了 Blender 5.2.1 侧视渲染：嘴和眼睛位于模型左端（局部 −X），尾鳍位于右端（局部 +X）。GLB 节点绕 X 轴的 90°旋转不改变这条纵向轴的正负方向。
- 发现原 Profile 将 `model_forward_axis` 设为 Positive X，与实际鱼头相反。已改为 `model_forward_axis = 1`（Negative X）及 `model_head_x = -0.4`，使鱼嘴朝学校速度方向，尾部摆动由后半身向尾鳍递增。
- 已运行 `godot --headless --path . --script res://tests/test_fish_resources.gd`：`[FISH_TEST] failures=0`，鱼种配置、模型加载及朝向基底断言均通过。Headless 输出 `No rendering device on load`，因此这不是 Godot Forward+ 实际画面验收；来源 GLB 的嘴/尾方向已通过 Blender 侧视图确认。

## 2026-10-30 鱼类日常速度调校

- 发现 `fast_pelagic` 每约 1.3–6 秒重选动作，会随机进入 burst；转向状态也有低于巡游的速度上限，导致动作切换时速度变化明显。
- 按用户指定规则调整共用鱼类 renderer：转向与巡游使用相同基础速度上限；删除日常 burst 的选择和额外推进；警戒、恢复不再获得高于巡游的速度倍率；只有 `is_fleeing` 惊吓状态应用 Profile 逃逸速度倍率。
- 现有鱼种逃逸倍率统一为 2.5，Profile 默认也改为 2.5。保留海鳟及其他鱼种巡游基准速度不变；海豚使用独立行为系统且未修改。
- 删除不再使用的 `turn_speed_factor`、`burst_speed_factor` 配置字段及 Profile 签名项。Profile 行为签名变化会使旧开发快照按现有校验流程拒绝并重新生成，不会静默解释为新行为。
- 自动鱼类测试：**NOT RUN**。静态引用检查确认不再存在旧倍率属性/日常 burst 引用；`git diff --check` 结果见本轮最终复核。运行中的游戏需重新加载/重启后才会读取新脚本及 Profile。
