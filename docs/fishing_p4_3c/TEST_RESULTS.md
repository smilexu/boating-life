# P4.3c — 测试结果

## 自动化检查

| 检查 | 结果 | 说明 |
|---|---|---|
| `godot --headless --path . --script res://tests/test_fishing_p4_3c.gd` | PASS | 连续/无效/间隔过长/换船/来源变化/探头跳变判定；原始深度变化保留；最大跳变诊断；四种窗口比例的迷你与展开布局避开 F3 面板；隐藏、展开、预览和设置生命周期；新增英文/简中翻译。 |
| `godot --headless --path . --script res://tests/test_fishing_p4_2.gd` | PASS | 声呐深度映射、迷你/展开/隐藏/重开、预览历史及 CanvasLayer 不变。 |
| `godot --headless --path . --script res://tests/test_fishing_p4_1.gd` | PASS | 真实扫描、DTM/波面数据、活动船切换、历史边界、鱼群与 RNG 隔离。 |
| `godot --headless --path . --script res://tests/test_fishing_p4_3a.gd` | PASS | Gain/Range 显示映射、迟滞、设置生命周期与中英文本。 |
| `godot --headless --path . --script res://tests/test_fishing_p4_3b.gd` | PASS | 聚合回波、Gain、鱼形标记及预览隔离。 |
| `godot --headless --path . --script res://tests/test_fishing_p2.gd` | PASS（重导入后复跑） | Authority、Encounter、渔获结算、Fish Finder 与 RNG 隔离。第一次运行时 CSV 翻译源已更新但导入的 `.translation` 尚旧，触发格式化错误和翻译断言失败；重新导入翻译资源后复跑通过。 |
| `godot --headless --editor --path . --import --quit` | PASS，带环境警告 | 导入成功并生成更新后的双语 Translation。Headless 输出既有文档 translation UID 重复警告、退出时 1 个 ObjectDB 实例泄漏警告，以及无渲染设备提示。 |
| `godot --headless --editor --path . --quit` | PASS，带环境警告 | 项目脚本类与编辑器项目加载完成；同样报告既有 UID 重复、ObjectDB 泄漏和无渲染设备提示。 |
| `git diff --check` | PASS | 无空白错误。 |

## 静态性能与隔离检查

- Fish Finder 仍使用现有单一 `FishFinderSensor`，扫描频率和历史容量未改。
- `_draw()` 只读已缓存的有界扫描历史，不查询 Authority School。
- 显示历史仍是最多 60 秒、默认约 180 列。新增最大跳变分析只遍历这份有界历史，并在 F3 诊断快照中计算。
- Gain、Range、鱼形标记、F3 避让只影响显示与布局；未修改声束、真实扫描回波、School population 或 P2 RNG。
- 未运行 Profiler、长时间内存观察或实际 GUI 尺寸操作。

## 未运行

- Forward+ 运行时的 1280×720、1600×900、1920×1080 与非标准比例画面验收：`NOT RUN`。Headless 几何测试通过不等于视觉确认。
- 旧截图所对应的扫描 ID、坐标和原始深度列：`NOT RUN / 数据不可用`，旧历史没有保存。
- 迷你/展开模式下实际鼠标点击、菜单层级、船切换与全屏切换：`NOT RUN`。
- 声呐实际 CPU/GPU 耗时和长时间资源增长测量：`NOT RUN`。
