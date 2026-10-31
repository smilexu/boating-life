# P4.3a 测试结果

| 检查 | 命令 | 结果 |
|---|---|---|
| Gain 映射、Auto 稳定/平滑、五档 Range、裁剪、切换、UI、预览隔离 | `godot --headless --path . --script res://tests/test_fishing_p4_3a.gd` | PASS，`failures=0`。 |
| P4.1 真实传感器、空间回波、历史与水深回归 | `godot --headless --path . --script res://tests/test_fishing_p4_1.gd` | PASS，`failures=0`。 |
| P4.2 Sonar 绘制、滚动、迷你/展开、预览回归 | `godot --headless --path . --script res://tests/test_fishing_p4_2.gd` | PASS，`failures=0`。 |
| P4.2.2 可见针鱼、鲱鱼、海鳟 School 空间回波 | `godot --headless --path . --script res://tests/test_surface_fish_visibility.gd` | PASS，`failures=0`。Headless 加载真实场景数据，没有 Forward+ 显示器验收。 |
| P2 / F3 预览隔离、Authority 和 Encounter RNG 回归 | `godot --headless --path . --script res://tests/test_fishing_p2.gd` | PASS，`failures=0`。 |
| Godot 编辑器导入、翻译导入与脚本解析 | `godot --headless --editor --path . --quit` | PASS，退出码 0。 |
| 空白与补丁格式检查 | `git diff --check` | PASS，无输出。 |
| Forward+ 展开控件布局、0.08 弱回波的真实屏幕亮度、玩家鼠标操作 | — | NOT RUN。Headless 结果不代替图形界面检查。 |

## 自动检查覆盖

- `map_echo_strength(0.08, gain)` 在 Gain 0/50/100 下严格单调；原始 0 始终为 0。
- Auto Gain 空历史返回原值；单个 0.08 回波只把目标值推至受限区间，不会映射为满亮度；扫描时间平滑更新。
- 原始回波 `echo_strength` 和 Sensor History 在 Gain/Range 切换后保持不变。
- Auto→Manual 继承当前 20 m 档位；5/10/20/30/50 m 均可选择；手动 5 m 裁掉 12 m 回波，底部超量程时不画在量程边缘。
- Manual 模式下 Auto 档位仍可更新，切回 Auto 显示最新自动档位。
- 扩展/迷你、隐藏/重开和 Debug Preview 启停均保留会话偏好；Preview 不更改真实扫描历史。

## 已见环境告警

编辑器导入报告仓库中已有的两组 Polar 文档翻译 UID 重复，以及退出时一个 ObjectDB 对象泄漏，退出码为 0。可见鱼群场景测试退出时报一个 RendererDummy Shader RID 泄漏；断言全部通过。
