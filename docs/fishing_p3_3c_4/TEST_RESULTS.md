# Fishing P3.3c.4 — 测试结果

## 自动化

- `godot --headless --path . --script res://tests/test_fishing_p3_3c_1.gd --quit-after 180 --log-file /tmp/fishing_p3_3c_4_test.log` — **PASS**，`failures=0`。覆盖鱼嘴固定、前段刚度、主弯 C 形与反向、尾部比例、Shader 参数上限、横摆方向/幅度/后期衰减，以及针鱼与海鳟的配置差异。
- `git diff --check` — **PASS**。

测试期间曾发现本地 Shader 变量与已有 `tail_u` uniform 重名，以及刚度断言采样点过宽；均已修正后重跑通过。Headless Dummy Renderer 仍输出一条 `Parameter "material" is null` 诊断，但测试进程退出码为 0，且没有 Shader 编译失败；该诊断发生于既有 UI 测试路径，不影响本次断言。

## 视觉检查

- Forward+ 运行时目视验收 — **NOT RUN**。检查时 Godot 前台只有 `main.tscn` 编辑器窗口，没有运行中的游戏窗口；Headless 结果不能代替鱼体形变的画面验收。
