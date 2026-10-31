# Fishing P3.2 测试结果

## Headless / 自动化

| 检查 | 命令 | 结果 |
|---|---|---|
| Godot 4.7.2 编辑器导入、脚本类注册和场景重载 | `godot --headless --path . --editor --quit` | PASS；本轮改动未报告脚本解析错误。输出中仍有仓库既有的 translation UID 重复警告，以及无渲染设备提示。 |
| P2 钓鱼逻辑回归 | `godot --headless --path . --script res://tests/test_fishing_p2.gd` | PASS，`failures=0`。包含 P2 候选、结算、防重复扣减、鱼探仪和资源渲染隔离。 |
| P3 实际流程与演出回归 | `godot --headless --path . --script res://tests/test_fishing_p3.gd` | PASS，`failures=0`。验证真实 Hook 自动开始 retrieval、自动 settlement、恢复拖钓、取消不结算；另验证真实 pending catch 阻止模拟。 |
| P3.1 视觉配置与相机逻辑回归 | `godot --headless --path . --script res://tests/test_fishing_p3_1.gd` | PASS，`failures=0`。覆盖五阶段时长、海鳟跃水/洗鳃时间点、鱼竿几何和 Fight Camera 输入循环。 |
| P3.2 模拟、播放控制与隔离 | `godot --headless --path . --script res://tests/test_fishing_p3_2.gd` | PASS，`failures=0`。无有效鱼群、船速为 0 时启动成功；阶段跳转、暂停、0.5×/2×、重播、停止和自动阶段推进均通过；Authority population、PendingCatch、CatchResult、P2 RNG 与 hazard 保持不变。 |
| 空白检查 | `git diff --check` | PASS，exit 0；同时对本轮新增/修改的未跟踪文件执行了 trailing-whitespace 扫描，无尾随空格。 |

## F3 模拟鱼种 UI 后续回归

| 检查 | 命令 | 结果 |
|---|---|---|
| 复现并验证延迟鱼种注册、下拉框填充、按钮启动/停止 | `godot --headless --path . --script res://tests/test_fishing_p3_2.gd` | PASS，85 项断言，`failures=0`。先让管理器鱼种列表为空创建面板，再恢复资源；验证下拉框出现 `sea_trout` / `needlefish`，可选择，Simulate Catch 启动共享演出、Stop Simulation 正确清理。 |

此修复只验证 UI 控件绑定和启动流程，不等同于 Forward+ 可视化验收。真实游戏窗口中的画面检查仍为 `NOT RUN`。

## 具体覆盖

- F3 模拟按钮在没有候选鱼群时启用。
- 模拟使用真实 species profile、长度范围和重量系数；preview 不生成真实 P2 事件或结算。
- 五个阶段的 seek 起点依照导出时长动态计算；每次跳转会应用同一演出状态更新路径。
- 模拟暂停只冻结搏鱼本地时间。播放速度测试使用确定性 delta，验证阶段时钟分别按 0.5× 与 2× 推进。
- 模拟启动期间已有 P2 trolling 状态保留；P2 encounter RNG 与累计 hazard 不前进，停止模拟后继续原拖钓。
- 模拟完整经过五阶段后自动清理；没有消耗 Authority fish。
- F3 新增模拟操作、单位、阶段格式和状态 key 已检查 English 与简体中文均有翻译。
- P3 自动真实捕获流程由现有 P3 集成测试覆盖：Hooked → 自动 retrieval → 真实 P2 settlement → Catch Presentation → 恢复 trolling。

## 未执行 / 限制

- Forward+ GUI 视觉验收：`NOT RUN`。Godot 进程在应用列表中，但当前 UI automation 无法取得窗口（`cgWindowNotFound`）。没有声称鱼体动画、鱼线穿插、水花画面或 Fight Camera 构图已通过视觉验收。
- 真实环境长时间等待自然中鱼：`NOT RUN`；P2 真实 hook 的状态流以确定性测试入口验证。
- Windows 图形界面回归：`NOT RUN`。

## 运行日志观察

- BathymetryManager 在 headless fixture 中提示缺少 ShaderMaterial；此测试不渲染海色，不影响钓鱼断言。
- 编辑器导入时检测到两组现有 `.translation` UID 冲突，路径在 `docs/sailing/polar_p25/` 和 `docs/sailing/polar_p215/`；未由本任务引入或处理。
- P2、P3、P3.1 既有定向测试分别为 `44`、`39`、`53` 项断言；P3.2 本轮 UI 回归后为 `85` 项断言。历史和本轮执行均报告 `failures=0`。
