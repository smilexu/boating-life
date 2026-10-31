# Fishing P3.3c.3 — 测试结果

| 检查 | 结果 | 说明 |
|---|---|---|
| `godot --headless --path . --script res://tests/test_fishing_p3_3c_1.gd --quit-after 180` | PASS，`failures=0` | 验证海鳟和针鱼模型、S/C 局部曲率、尾部幅度、体长缩放、嘴部/鱼线挂点、早期爆发和后期衰减。日志：`/tmp/fishing_p3_3c_3_final.log`。退出前 Dummy Renderer 有既有 `material is null` 诊断输出，不影响测试断言及退出码。 |
| `godot --headless --path . --script res://tests/test_fishing_p3_2.gd --quit-after 240` | PASS，`failures=0` | 验证 F3 3.0× 默认值、0.5–4.0 范围、模拟播放中的即时修改，以及英语/简体中文 key。首次运行因 CSV 翻译尚未导入而有 2 个翻译断言失败；执行编辑器导入后重跑通过。日志：`/tmp/fishing_p3_3c_3_debug_ui_retry.log`。 |
| `godot --headless --editor --path . --quit` | PASS，退出码 0 | 导入新增翻译并注册相关脚本。Godot 提示无渲染设备、退出时 1 个 ObjectDB 实例泄漏，以及两个仓库既有 sailing 文档翻译 UID 重复。日志：`/tmp/fishing_p3_3c_3_import.log`。 |
| `git diff --check` 与本轮文件空白扫描 | PASS | 无尾随空白或空白错误。 |
| Forward+ 实际动画观察 | NOT RUN | 编辑器仍停在场景编辑视图，未成功启动游戏运行窗口；不能据此确认真实画面中的弯曲强度、自交或裁剪。 |

Headless 使用 Dummy Renderer，能够验证脚本、资源、CPU 形变曲线和 Shader 参数传递，但不编译/观察真实 Metal 画面。不得将其视为视觉验收通过。
