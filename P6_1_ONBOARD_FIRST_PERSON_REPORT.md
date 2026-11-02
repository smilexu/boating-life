# P6.1 船上第一人称活动报告

## 实现

- 在 `scenes/Boat.tscn` 中仅为 starter cargo boat 配置 `OnboardActivityController` 与甲板活动资源。活动区域按船体局部坐标定义，含甲板碰撞面和防跌落边界；边界可通过 F3 显示。
- 新增 `scripts/onboard_activity_controller.gd`、`scripts/onboard_activity_profile.gd` 与 `resources/onboard_activity/starter_cargo_boat.tres`。控制器提供 WASD、鼠标观察、Space 跳跃和 `set_movement_locked(bool)`；玩家位置保存在船体局部坐标中，船舶运动及波浪姿态继续运行。
- 扩展现有 `BoatFollowCamera` 的 O 键视角循环。普通状态仍是原有 Follow/God；船钓准备活动启动后才加入甲板第一人称。离开第一人称不会结束活动，结束活动则移除该视角并恢复普通视角。未配置活动区域的船型保留原视角循环。
- `BoatHUD` 复用右上角活动菜单新增 Boat Fishing 入口和“准备中”面板。进入活动不抛竿、不启动中鱼判断；与拖钓互斥，双方冲突时拒绝启动并提供中英文提示，不会暗中停止另一活动。切换到不支持的帆船时结束准备状态。
- 第一人称期间仅屏蔽与玩家移动按键冲突的船舶手动输入；不清除速度、油门、帆角或自动巡航。结束时若玩家仍在跳跃，会安全落回配置甲板面并停用临时碰撞体。

## 活动区域与碰撞补充

- 检查 `first_boat_optimized.glb` 装配到船体后的包围范围约为局部 X `[-1.28, 1.28]`、Z `[-3.60, 3.60]`。资源现在只开放船尾外部甲板上的倒角八边形，X `[-0.90, 0.90]`、Z `[0.12, 3.36]`；不把整船包围盒作为活动区。前缘封住舱口，边缘留在船舷内侧。该船模型是合并网格，因此舱口以资源配置的封闭边界阻挡，没有把渲染网格直接用作动态碰撞。
- 可行走面使用凸多边形棱柱碰撞；边界按每条多边形边生成连续盒形碰撞，含倒角角点重叠。墙高为 2.25 m，覆盖配置跳跃高度；角色步速受 4 m/s 上限保护。移动通过 CharacterBody 碰撞滑停，不做越界后传送。
- 船上活动碰撞独占 3D physics layer 6 `Onboard Activity Bounds`，只有活动玩家的碰撞掩码查询此层。未来抛投射线应继续使用自己的查询掩码并忽略 layer 6；此轮没有抛投逻辑。
- F3 活动区域可视化显示淡色可行走面、禁行边界线框和玩家胶囊线框。线框只在调试显示时创建，关闭 F3 即隐藏，不参与碰撞。

## 修改文件

`scenes/Boat.tscn`、`scripts/boat_controller.gd`、`scripts/boat_follow_camera.gd`、`scripts/boat_hud.gd`、`scripts/fishing_debug_panel.gd`、`scripts/fishing_player_panel.gd`、`scripts/onboard_activity_controller.gd`、`scripts/onboard_activity_profile.gd`、`resources/onboard_activity/starter_cargo_boat.tres`、`resources/translations/fish_species.csv` 及对应英文/简体中文导入翻译资源；新增 `tests/test_p6_1_onboard_activity.gd`。

## 验证

- `godot --headless --path . --script tests/test_p6_1_onboard_activity.gd` — **PASS**。覆盖活动入口与状态、O 键行为、WASD/跳跃/锁定、活动区域边界、自动巡航与船速隔离、空中结束清理、拖钓互斥、帆船不支持状态及中英文标签。
- `godot --headless --path . --script tests/test_p6_1_onboard_activity.gd`（活动区域补充）— **PASS**。新增覆盖舱口、左右舷和船尾约束，4 m/s 步速、跳跃撞边、胶囊净空、F3 可视化开关、船体倾斜/转向时船体局部位置稳定。
- `godot --headless --path . --editor --quit` — **退出码 0**，项目扫描及场景/脚本导入完成。日志仍报告 `editor_settings-4.7.tres` 无法写入、macOS 证书读取错误和一个退出时 ObjectDB 泄漏；没有 P6.1 脚本解析错误。还出现仓库 `docs/sailing` 下两组既有重复 translation UID 警告，本任务未修改这些文件。
- P6.1 场景测试结束时另有一个 Godot DummyShader RID 泄漏提示；所有断言通过，未显示活动碰撞对象残留。此退出提示未作为功能测试失败。
- `git diff --check` — **PASS**。
- Forward+ 人工检查 — **部分完成**：在 starter cargo boat 运行时检查第一人称甲板、舱口前缘与 F3 边界线框；最初的实心调试墙会遮挡视线，已改为线框并复查。未完成所有真实航速/海况及窗口尺寸矩阵。Windows 未运行。

## 限制

首阶段只配置 starter cargo boat；Nordic 28 暂不支持船上活动。可行走区是依该船模型手工配置的凸多边形和简化碰撞代理，不是渲染网格自动生成的逐物件碰撞；测试模型的舱口入口被整体边界封闭。第一人称在正常航行/自动巡航和模拟倾斜下已有自动化稳定性检查，完整真实海况仍需玩家观察。P6.2 可调用 `set_movement_locked(bool)`；本轮未接入抛竿或任何船钓状态机。
