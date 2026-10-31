# 测试结果

## 本轮及相关检查

| 检查 | 结果 | 备注 |
|---|---|---|
| `godot --headless --path . --editor --quit` | PASS | 脚本类注册与资源导入完成；有既存文档翻译 UID 重复提示和退出时 ObjectDB 泄漏警告。 |
| `godot --headless --path . --script tests/run_s1_c8_integration.gd` | PASS | 主场景集成 0 failures；包含活动生命周期、运行时中英切换与语言持久化、鱼探仪/海图、两船切换及帆船布局。退出时有 Dummy Shader RID 泄漏警告。 |
| `godot --headless --path . --script tests/test_fishing_p5_1_2_hud.gd` | PASS | 9 项深度基准、水层匹配及 P2 速度规则检查。 |
| `godot --headless --path . --script tests/test_navigation_hud_format.gd` | PASS | 118 项航行格式与响应式布局断言。 |
| `godot --headless --path . --script tests/test_fishing_p2.gd` | PASS | `[FISHING_P2] failures=0`。 |
| `godot --headless --path . --script tests/test_fishing_p3_2.gd` | PASS | `[FISHING_P3_2] failures=0`；真实/模拟搏鱼流程隔离回归。 |
| `godot --headless --path . --script tests/test_fishing_p4_1.gd` | PASS | `[FISHING_P4_1] failures=0`。 |
| `godot --headless --path . --script tests/test_fishing_p4_2.gd` | PASS | `[FISHING_P4_2] failures=0`。 |
| `godot --headless --path . --script tests/test_fishing_p4_3a.gd` | PASS | `[FISHING_P4_3A] failures=0`。 |
| `godot --headless --path . --script tests/test_fishing_p4_3b.gd` | PASS | `[FISHING_P4_3B] failures=0`。 |
| `godot --headless --path . --script tests/test_fishing_p4_3c.gd` | PASS | `[FISHING_P4_3C] failures=0`。 |
| `godot --headless --path . --script tests/test_sailboat_navigation_instrument.gd` | FAIL | 25 项旧 SailboatLab 断言失败，包含 TabContainer 数量及 Nordic 28 mast/boom 尺寸/锚点；当前 rig 的实测配置为 mast 9.3 m、boom 4.4 m，而测试仍要求 6.5 m / 3.3 m。该测试检查的是实验场景的帆装几何，不是主场景 HUD；本轮没有改船体配置或为迎合旧夹具修改测试。 |
| `git diff --check` | PASS | 无空白错误。 |
| 鱼探仪 Profiler / 长时间打开关闭资源观察 | NOT RUN | 只检查了 UI 复用现有传感器历史、未增加扫描器；没有收集鱼探仪专项耗时或长期内存数据。 |
| Forward+ 交互、真实窗口尺寸与多显示器检查 | NOT RUN | 本轮未运行图形界面，不能据此确认实际遮挡或视觉效果。 |

上述 P2/P3/P4 回归针对底层不变接口进行；本轮没有改变这些系统的规则。Headless 主场景仍有测试退出时的图形 dummy shader RID 警告，不影响断言结果，但未在本轮处理。
