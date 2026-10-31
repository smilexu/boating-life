# Fishing System P3.1 — 测试结果

日期：2026-10-30

## 自动化检查

| 命令 | 结果 | 说明 |
|---|---|---|
| `godot --headless --path . --script res://tests/test_fishing_p2.gd` | PASS | `[FISHING_P2] failures=0`；P2 核心接口与概率/结算回归。 |
| `godot --headless --path . --script res://tests/test_fishing_p3.gd` | PASS | `[FISHING_P3] failures=0`；真实 Authority hook、五阶段快速时序、结算、天然体长、停止取消和恢复拖钓。Bathymetry fixture 输出既有无材质提示，不影响断言。 |
| `godot --headless --path . --script res://tests/test_fishing_p3_1.gd` | PASS | `[FISHING_P3_1] failures=0`；56 秒配置、两鱼种 Profile、固定 MultiMesh 拓扑、竿尖弯曲范围、定位 key、Fight Camera O 循环、自动恢复、手动离开、收线阶段注视偏移及阻尼镜头脉冲。 |
| `godot --headless --path . --editor --quit` | PASS | Godot 4.7.2 导入/脚本类注册/项目场景资源扫描退出码为 0。旧 Polar 文档存在重复 translation UID 警告；编辑器退出时曾报告 1 个 ObjectDB 实例泄漏。 |
| `godot --headless --path . --quit-after 1` | PASS | 项目主场景启动一帧并退出，场景/资源加载日志正常；Headless 输出 `No rendering device on load`，退出时报告 1 个 RendererDummy shader RID 泄漏。此检查不能验证 Forward+ 画面。 |
| `git diff --check` | PASS | 在代码、测试和最终文档完成后执行。 |

## 图形与平台验收

| 项目 | 结果 | 说明 |
|---|---|---|
| Godot Forward+ 项目启动 | PASS | `godot --path .` 输出 Godot 4.7.2、Metal 3.2、Apple M2 Pro，并开始加载海图/海岸和鱼群场景。该运行进程保持开启。 |
| 实际搏鱼过程截图观察 | NOT RUN | CUA 能读取编辑器，但无法切换到 CLI 启动的游戏运行窗口；未观察 56 秒动画。 |
| Fight Camera 实际构图/遮挡 | NOT RUN | 需在游戏窗口中用 F3 触发有效 hook 并实际切换 O 视角检查。 |
| Windows | NOT RUN | 当前环境为 macOS。 |

## 可见性人工检查清单

1. 在 starter cargo boat 和 Nordic 28 分别通过 F3 触发有效中鱼，确认 1 秒内能看到明显弯竿。
2. 观察 3–18 秒反复挣扎、卷线器短暂反转和 18–40 秒靠近过程，确认鱼不是突然生成在船边。
3. 观察水面扑腾、水花、快速但不慢动作的 2 m 提升、8 秒渔获展示及恢复拖钓。
4. 在 hook 前/后用 O 键循环，验证玩家离开 Fight Camera 后不会被抢回，演出结束只在仍处于 Fight Camera 时恢复旧视角。
5. 检查相机、鱼、竿、船尾结构、水花之间的穿模与画面边缘裁切。

## 2026-10-30 卷轴与海鳟水面动作修正

| 命令 | 结果 | 说明 |
|---|---|---|
| `godot --headless --path . --editor --quit` | PASS | 重新扫描脚本类并导入 `resources/translations/fish_species.csv`，退出码 0。显示仓库里既有的重复 translation UID 警告和 1 个 ObjectDB 泄漏提示。 |
| `godot --headless --path . --script res://tests/test_fishing_p3_1.gd` | PASS | `[FISHING_P3_1] failures=0`。新增卷轴轴向、海鳟水下起跳/离水峰值/回水、实际鱼模型侧翻洗鳃及后续提升断言。 |
| `godot --headless --path . --script res://tests/test_fishing_p3.gd` | PASS | `[FISHING_P3] failures=0`。船只场景、钓竿与真实 P2 中鱼/结算流程仍通过；测试输出包含既有 Bathymetry 无材质提示。 |
| Forward+ 实际搏鱼画面观察 | NOT RUN | 当前屏幕自动化未能取得 Godot 窗口（`getApp("Godot")` 返回无可见窗口）；没有声称实际画面通过。 |

第一次追加测试因测试误用了带 `get_` 的方法名（实际方法是 `_get_...`），以及 CSV 新 key 尚未重新导入而失败；修正调用并运行编辑器导入后，P3.1 测试通过。测试进程随后正常退出；曾停止一次该失败运行留下的挂起 Headless 测试进程。

人工观察时请触发有效海鳟 hook 后保持演出运行到第 40 秒附近；从 hook 起约 41 秒才开始跃出水面，约 42–45 秒侧翻洗鳃。不要点击“立即完成收线”，该调试操作会跳过演出。

## 2026-10-30 竿架/卷线器/鱼线修正回归

| 命令 | 结果 | 说明 |
|---|---|---|
| `godot --headless --path . --script res://tests/test_fishing_p3_1.gd` | PASS | `[FISHING_P3_1] failures=0`。新增两船挂点上移 0.20 m、正收线输入卷轴方向、鱼位于竿架后方左右移动并沿采样水面露出、线端跟随鱼头、入水点位于竿尖后方等检查。 |
| `git diff --check` | PASS | 本轮脚本、资源、测试和文档修改无空白错误。 |
| Forward+ 实际 3D 画面 | NOT RUN | Headless 可验证位置计算与状态，不能验证水面材质下的线可见性、栏杆穿模、跃水和洗鳃的视觉可读性。需用更新后的游戏实例在 Fight Camera 中人工确认。 |

有一次临时断言尝试读取 Headless RendererDummy 的 MultiMesh 实例变换，返回默认变换而失败；这是无渲染后端下无法用该读取值验收 GPU 实例缓冲的限制。断言已改为检查生产逻辑输出的鱼/线世界端点和活动状态，未把 Dummy 缓冲结果当作运行画面结论。

## 2026-10-30 鱼线厚度与甲板落点调整

- 自动化测试：`NOT RUN`。本轮按用户截图做局部视觉修改，未执行测试命令。
- Forward+ 画面检查：`NOT RUN`。需要在 starter cargo boat 和 Nordic 28 上确认远处线条可读性、鱼落在甲板空位，以及越栏杆的短弧是否自然。
