# P4.2.2 测试结果

| 检查 | 命令 | 结果 |
|---|---|---|
| 空间代理、中心命中、边缘弱回波、外部无回波、确定性和历史 | `godot --headless --path . --script res://tests/test_fishing_p4_1.gd` | PASS，`failures=0`。测试输出的 fixture 使用固定 10° 声束。 |
| Sonar 绘制映射、预览历史隔离、参数刷新、迷你/展开模式、中英翻译 | `godot --headless --path . --script res://tests/test_fishing_p4_2.gd` | PASS，`failures=0`。 |
| F3 启停预览与真实传感器历史隔离、P2 鱼群/RNG 不变回归 | `godot --headless --path . --script res://tests/test_fishing_p2.gd` | PASS，`failures=0`。 |
| 与可见实例对应的针鱼、鲱鱼、海鳟 Authority School 空间检测 | `godot --headless --path . --script res://tests/test_surface_fish_visibility.gd` | PASS，`failures=0`。此 Headless 场景确实检查三种鱼。 |
| Godot 编辑器资源导入与脚本解析 | `godot --headless --editor --path . --quit` | PASS，退出码 0。 |
| 空白和补丁格式检查 | `git diff --check` | PASS，无输出。 |
| 真实 Mac Forward+ 声呐画面与声束视觉表现 | — | NOT RUN。本次没有在运行中的图形游戏里作新的视觉验收。 |

## 三种可见鱼群场景的实际数值

来自 `test_surface_fish_visibility.gd` 的真实场景数据；距离是可见 MultiMesh 鱼与 Authority 锚点偏移，声呐本身仍只查询 Authority 学校：

| Species | 可见鱼偏移/锚点距探头 | 代理半径 | 代表目标深度 | 声束半径 | overlap | echo strength | 判定 |
|---|---:|---:|---:|---:|---:|---:|---|
| Needlefish | 4.44 m | 5.72 m | 0.46 m | 0.08 m | 0.134 | 0.077 | partial_overlap |
| Herring | 2.39 m | 2.64 m | 1.82 m | 0.32 m | 0.100 | 0.099 | partial_overlap |
| Sea Trout | 2.72 m | 5.72 m | 1.98 m | 0.35 m | 0.713 | 0.083 | school_volume_detected |

这证明已观察到的三个锚点偏移场景都能进入空间检测并得到聚合回波；不能由 Headless 数值推出玩家屏幕上的可见亮度验收结论。

## 已见警告

- 编辑器 Headless 导入仍报告仓库既有 Polar 文档翻译文件 UID 重复，以及退出时 1 个 ObjectDB 对象泄漏；退出码为 0，未报告本次脚本解析错误。
- `test_surface_fish_visibility.gd` 退出时报告 1 个 RendererDummy Shader RID 泄漏；所有断言通过。这是测试进程退出清理告警，不代表 Forward+ GPU 性能验证。
