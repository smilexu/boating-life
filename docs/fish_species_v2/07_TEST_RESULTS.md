# P1.6 自动验证记录

**状态：**PASS（自动/Headless 验证）；Forward+ 画面验收 `NOT RUN`  
**日期：**2026-10-30  
**Godot：**4.7.2 stable official

## 阶段目标与验收

- 验证四个稳定鱼种 ID、Profile、水域/深度/学校规模约束及相同配置确定性。
- 验证 index 重排和 Profile 数组反转不会改变学校布局；旧 schema/layout 和不同生态配置快照被明确拒绝。
- 验证海鳟 GLB 可导入并匹配现有 MultiMesh renderer 的 mesh/surface 接口。
- 验证 F4 鱼种详情及 F3 鱼群观察 UI 的 `en` / `zh_CN` 翻译 key、可见/逻辑层和 F4 查询。
- 验证渲染预算与 Authority population 分离、WorldTimeManager 驱动的耗减恢复和快照往返。
- 环境支持的 Headless 自动测试运行；Forward+ 模型材质/朝向目视检查明确报告是否执行。

## 实际命令与结果

| 命令 | 结果 | 实际覆盖及证据 |
|---|---|---|
| `godot --headless --editor --path . --quit` | PASS，exit 0 | 完成文件系统扫描、全局类注册、Sea Trout GLB 与鱼类 CSV 导入；没有鱼类资源导入错误。出现两个已有 sailing telemetry `.translation` UID duplicate 警告（P2.5/P2.15 文档目录），另有无渲染设备与退出 ObjectDB warning。 |
| `godot --headless --path . --script res://tests/test_fish_resources.gd` | PASS，exit 0，`[FISH_TEST] failures=0` | 四 Profile、两语言 key、相同 seed/layout 确定性、index 反向重排与同生态快照恢复、Profile 顺序反转、生态配置变化签名拒绝、旧 schema/layout 拒绝、DTM/学校范围、四鱼模型与 Sea Trout 单 Mesh/Surface、F4 双语详情、F4 raster 分片、F3 观察、MultiMesh 和渲染预算/Authority 数量隔离。Seed `20261016` 生成 needlefish 863 校/5,657 尾、herring 461/30,025、stickleback 148/3,201、sea trout 38/84，共 1,510 校/38,967 尾。 |
| `godot --headless --path . --script res://tests/test_surface_fish_visibility.gd` | PASS，exit 0，`[SURFACE_FISH_TEST] failures=0` | 三种表层周期鱼同一 Authority 状态中的视觉/逻辑学校、F4 两种 marker、F3 不选择深层逻辑群、局部观察不移动学校或改 population、鱼群水层与有限水面 reveal。Seed `20261016`：needlefish 687 visual/176 logical，herring 184/277，sea trout 34/4。 |
| `godot --headless --path . --script res://tests/test_fish_population_recovery.gd` | PASS，exit 0，14 项 PASS，`failures=0` | 模拟 population 耗减至 0、稳定学校 ID、指数恢复、未耗减学校不变、世界时间回拨、重新推进、baseline 上限、schema 3/layout 5 snapshot 往返及非法恢复状态拒绝。 |
| `git diff --check` | PASS | 最终文件差异无空白错误；文档补全后重跑结果记录于最终审查。 |

## 性能与确定性观察

- Authority 测试遥测：1,510 校；最近一次初始化约 323.7 ms，测试步进累计约 779.7 ms、16 帧，最差 budgeted frame 约 5.07 ms。多次运行的测试进程时间有波动；这不是发行构建性能承诺或旧版 A/B。
- Renderer 测试保留每鱼种 MultiMesh batch；测试将 `maximum_visible_fish` 调低后 Authority 总人口不变。F4 raster incremental-work 断言小于 12 ms/片通过。
- 以上测量不表示 Forward+ 实际鱼体材质、GPU Draw Call 或帧率已经验收；Headless 日志明确显示 `No rendering device on load`。

## 警告与未执行项目

- Headless 测试进程退出时仍输出 DummyShader RID leak warning；编辑器扫描还报告 `ObjectDB instance was leaked`。它们发生于测试进程关闭阶段，测试脚本本身 exit 0 且 failure counter 为 0；本阶段未据此宣称运行时无泄漏。
- 已有重复 UID 警告定位于 `docs/sailing/polar_p25/...` 与 `docs/sailing/polar_p215/...` 的 sailing 翻译数据，与鱼类 CSV/Sea Trout 导入无关；本阶段未修改这些历史文件。
- Godot Forward+ 鱼体画面：**NOT RUN**。需人工确认 Sea Trout 的朝向、表面材质、缩放，以及 F3 水下显示；Headless 的 Mesh/Surface/BaseColor 检查不能替代画面检查。
- 未实现捕鱼消费者、捕捞人口扣减调用或鱼类持久存档流程；恢复算法仅通过模拟扣减入口验证。当前项目没有独立鱼类玩家存档，旧开发 snapshot 由 schema/layout/profile signature 明确拒绝。

## 2026-10-30 海鳟朝向复核

| 检查 | 结果 | 证据与边界 |
|---|---|---|
| `Blender 5.2.1 --background --python /private/tmp/inspect_seetrout_orientation.py` | PASS | 侧视渲染可辨识鱼嘴/眼睛在局部 −X、尾鳍在局部 +X；实际据此修正 Profile。临时诊断脚本和 PNG 保存在 `/private/tmp`，不属于项目运行时资源。 |
| `godot --headless --path . --script res://tests/test_fish_resources.gd` | PASS，`[FISH_TEST] failures=0` | Sea Trout 负 X 头部配置、方向基底、GLB PackedScene、Mesh/Surface/材质和现有鱼类回归检查通过。日志有 `No rendering device on load` 及退出时 DummyShader RID 警告。 |
| Godot Forward+ 实际游戏视角 | NOT RUN | 尚未在主游戏实时画面确认游动时鱼嘴朝速度方向；Headless 不能替代此项检查。 |

## 2026-10-30 鱼类日常速度规则变更

| 检查 | 结果 | 证据与边界 |
|---|---|---|
| 静态引用检查 | PASS | `rg` 确认不再有 `turn_speed_factor` / `burst_speed_factor` 属性引用；日常 burst 选择和推进分支已删除。 |
| 自动鱼类测试 | NOT RUN | 本轮未要求执行；运行时游速和转向效果未验证。 |
| 海豚行为 | NOT MODIFIED | 改动限于鱼类共用 renderer、鱼种 Profile 和鱼类 Authority 的 Profile 签名；未改独立海豚系统。 |
| `git diff --check` | PASS | 本轮代码与文档差异无空白错误；未运行 Godot 自动测试。 |
