# Fishing P4.2 — 测试结果

运行环境：Godot 4.7.2 stable，Apple Silicon Mac；Headless 自动化及本机 Forward+ 游戏窗口。

## 自动化

| 命令 | 结果 | 结果摘要 |
|---|---|---|
| `godot --headless --path . --script res://tests/test_fishing_p4_2.gd` | PASS | 17 项检查通过，`failures=0`。覆盖深度/时间映射、自动量程与无效底部、迷你/展开/隐藏、层级恢复、F3 诊断、英文及简体中文文案。 |
| `godot --headless --path . --script res://tests/test_fishing_p4_1.gd` | PASS | P4.1 几何、真实学校聚合回波、深度基准、稳定性、历史容量、停船扫描、船只切换及无效底部检查通过，`failures=0`。 |
| `godot --headless --path . --script res://tests/test_fishing_p2.gd` | PASS | P2 相关测试全通过，`failures=0`；包括扫描共享 Authority 数据、真实学校回波、鱼数不变及 Encounter RNG 不受扫描影响。 |
| `godot --headless --editor --path . --quit` | PASS | 项目扫描、脚本类注册与资源导入退出码 0。输出两个已有 Polar 翻译文件 UID 重复警告、Headless 无渲染设备提示及一个退出时 ObjectDB 泄漏警告；它们未定位到 P4.2，本次不处理。 |
| `git diff --check` | PASS | 无空白错误或补丁格式问题。 |

P4.1/P2 fixture 会报告 BathymetryManager 缺少 ShaderMaterial 引用的预期警告；数据加载与相关测试仍通过。

## Forward+ 画面检查

| 检查 | 结果 | 观察 |
|---|---|---|
| 迷你模式 | PASS（本机目视） | 右下角显示标题、探头至底部深度、kn、量程、时间/深度网格；有效空扫描有明确空回波状态。 |
| 展开模式 | PASS（本机目视） | 大图正常绘制，海底暖色回波可见；发现被其他 HUD CanvasLayer 遮挡后将承载层在展开时提升至 90，现可见，收起时恢复。 |
| 隐藏/重开与键位干扰 | PARTIAL | UI 的开合通过目标按钮及 Headless 检查；本机画面确认迷你和展开。O 键/F3 输入逻辑未改，未单独完成全部键位交互组合。 |
| 有实际鱼群回波的 Forward+ 画面 | NOT RUN | 当前目视测试位置为空扫描，没有鱼群进入当前声束；真实回波绘制有 P4.1/P2 数据测试覆盖，但其屏幕观感需在有效回波位置人工确认。 |
| Windows、多个宽高比及其他刷新率 | NOT RUN | 当前无目标平台设备验证。 |

未进行性能基准采样；本阶段使用有限历史 `Control._draw()`，不声明具体 FPS 收益或 GPU 成本数据。
