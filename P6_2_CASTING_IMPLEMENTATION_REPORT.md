# P6.2 船上第一人称抛投实现报告

## 修改内容

- `scenes/Boat.tscn`：在测试用机动船上挂接独立的 `BoatFishingCastingSystem`。
- `scripts/boat_fishing_casting_system.gd`：新增船钓演出组件，维护 `READY / CASTING / WAITING / RETRIEVING` 状态；生成简化鱼竿、鱼线和鱼饵视觉对象。
- `scripts/boat_hud.gd`：船钓状态面板显示动态状态、操作提示，并在鱼饵入水等待时提供收竿按钮；结束活动时清理当前抛投。
- `scripts/onboard_activity_controller.gd`：移动锁定时将空中的玩家安全落到当前船体局部甲板位置，再冻结局部移动。
- `resources/translations/fish_species.csv` 及其导入翻译资源：新增中英文状态、操作和抛投失败提示。
- `tests/test_p6_2_casting.gd`：新增船钓场景集成测试。

## 实现方式

抛投鱼竿是轻量程序化网格，挂在 P6.1 船体局部活动控制器下。待机时随玩家甲板位置和朝向更新；抛投开始时固定当前持竿姿势，O 键只切换相机，不会重置钓位、鱼竿、鱼线或鱼饵。

鼠标左键仅在船钓活动的第一人称、待机状态、且鼠标没有悬停在 UI 控件上时触发抛竿。抛投方向需要朝下；通过重复采样 `WaveSampler.sample_physics_surface()` 求动态水面的落点，并限制水平距离为 3–25 m。落点还需通过现有 Bathymetry 有效水域检查，抛投射线遇到障碍物则拒绝。渔线查询排除了 P6.1 专用玩家/活动边界碰撞层。

抛投动作约 0.92 秒，鱼饵沿带弧度的轨迹入水。鱼饵之后以世界坐标更新，使用船舶位移估算水流拖曳并保持在动态水面下；鱼线长度上限为 52 m，约束只移动鱼饵，不向船施力。入水下沉深度为 0.62 m，过渡约 1.15 秒。鱼线由低成本分段管状网格绘制，不使用物理绳索。

等待状态下可按 `R` 或点击右上船钓面板的“收竿”按钮。二者调用同一入口，约 0.72 秒收回鱼线和鱼饵，随后解锁玩家移动。等待期间可以按 O 返回驾驶视角继续航行，也可以再次进入第一人称；拖钓 Authority、Encounter RNG、中鱼与结算接口均未接入或修改。

## 测试结果

- `godot --headless --path . --script tests/test_p6_2_casting.gd` — **PASS**。覆盖左键抛投、有效水域落点、自动进入等待、移动锁定、持续航行/自动巡航、O 切换往返、鱼饵世界位置连续、驾驶 HUD 收竿、移动恢复、重复抛投和结束活动清理。
- `godot --headless --path . --script tests/test_p6_1_onboard_activity.gd` — **PASS**。P6.1 活动区域、输入隔离、移动锁定和拖钓互斥回归通过。
- `godot --headless --path . --editor --quit` — **PASS**。Godot 4.7.2 项目脚本及场景导入完成。
- `git diff --check` — **PASS**。

Headless 退出日志中仍有 Renderer DummyShader RID 清理提示；Editor 导入还报告 `docs/sailing` 中既有的重复 translation UID 警告。本轮未修改这些文档资源，测试断言均通过。

## 视觉验收与限制

Forward+ 运行命令 `/Applications/Godot.app/Contents/MacOS/Godot --path /Users/smixu1/dev/boat-life-simulator` 已启动场景；启动日志确认 Metal 3.2 / Forward+（Apple M2 Pro），且运行时资源加载完成。**交互式画面检查：NOT RUN**，当前工具只能看到 Godot Project Manager，无法操作该游戏窗口。结束这次启动进程时使用了 Ctrl-C，渲染器输出若干 RID 清理警告；这不作为运行时功能通过或失败的视觉证据。

仍需人工在 Forward+ 中确认：第一人称鱼竿是否处于舒适的右下构图、线在远距离下是否清楚、鱼饵入水点是否贴合可见波面，以及驾驶视角下鱼线是否被船体遮挡。抛投水域采用海图有效数据和碰撞射线作保守筛选；海图无效区域会拒绝落点，尚未在人工画面中覆盖岸线与复杂障碍场景。
