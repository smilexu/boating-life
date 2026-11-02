# P6.3.1 — 单钩船钓中鱼闭环报告

## 实现

- `scripts/fishing_encounter_system.gd`：在既有鱼群 Authority 中增加船钓候选查询、按游戏时间累计的低频中鱼风险、待咬钩状态和单鱼结算。候选按鱼饵世界位置及实际水层查询，并校验学校种群、可用状态、鱼种支持的钓法和钓组拟饵标签。船钓使用独立随机流，避免改变原拖钓判定序列。
- `scripts/boat_fishing_casting_system.gd`：只在单钩亮片已入水并处于 WAITING 时运行自然判定。浅于 6 m 时生成一个与已授权候选对应的临时鱼种模型，沿平滑弯曲路径游向亮片；鱼接触亮片后才确认咬钩。6 m 及更深可以跳过可视化接近，但仍可正常中鱼。自动搏鱼期间由真实线长、P3 出线状态和船钓鱼饵位置更新线长、鱼竿受力及音效。
- `scripts/fishing_rod_system.gd`：将船钓咬钩接入现有 P3 自动搏鱼、逐步收线、出水展示及结果信号。船钓保持玩家选定视角，不被拖钓战斗镜头接管。
- `scripts/fishing_player_panel.gd`：按中鱼记录中的 `fishing_method` 过滤共享 Encounter 状态，避免把船钓的 `HOOKED/RETRIEVING` 误认为拖钓。
- `scripts/fishing_pending_catch.gd`、`scripts/fishing_catch_result.gd`：增加来源钓法和 `debug_spawned` 标识。
- `scripts/boat_fishing_rig_profile.gd`、`resources/boat_fishing/single_jig.tres`、鱼种资源：通过已有鱼种钓法与拟饵标签配置支持关系；当前单钩亮片可匹配 needlefish 和 sea trout。
- `scripts/fishing_debug_panel.gd`、`scripts/boat_hud.gd`、`resources/translations/fish_species.csv`：F3 → Fishing 增加“生成测试鱼并咬钩”按钮、失败原因和测试渔获标记，支持中英文。
- `tests/test_p6_3_1_single_jig.gd`：新增单钩闭环定向集成测试。

## Authority、收鱼和结算

自然中鱼调用 `FishingEncounterSystem.evaluate_boat_fishing_candidates()`，采样真实鱼群并以候选鱼种、种群状态、钓组兼容性、水层重叠、鱼饵相对运动计算温和的机会权重。空水域、错误水层或不兼容鱼种不会产生候选；判定按累计游戏时间执行，不按渲染帧数增加机会。

浅水接近阶段先创建待处理中鱼记录，但不提前扣减学校数量、不显示已中鱼、不播放卸力反馈。鱼到达钩位后才发送共同的 `fish_hooked` 事件。成功收鱼时由 Authority 对自然鱼群扣减一条，并产生唯一 `FishingCatchResult`；候选阶段或视角切换不会重复结算。自动收线期间线长逐步变化，鼓轮和收线/卸力音效继续跟随线长变化。完成或取消会清理临时鱼、待处理事件、弯竿和循环音效。

F3 测试要求船钓活动已开启、单钩亮片已入水、当前没有其他中鱼流程，并使用现有鱼种选择器。测试鱼绕过自然候选与随机判定，带 `debug_spawned` 标记、不占用或扣减真实学校数量，但仍经过相同的接近、咬钩、P3 自动收鱼和结果信号。重复点击、活动结束等情况不会生成重复事件。项目当前的 `FishingCatchResult` 明确是会话级结果；库存/销售持久化不在现有系统范围，因此这里不虚构持久化库存写入。

## 定向测试

以下均已运行：

- `godot --headless --path . --script tests/test_p6_3_1_single_jig.gd`：通过，失败断言 0。覆盖真实 Authority 候选、空水域/水层拒绝、浅水接近后才咬钩、渐进收线与单条种群扣减、F3 测试鱼共享自动收鱼且不扣自然种群、重复触发保护和活动取消清理。
- `godot --headless --path . --script tests/test_fishing_p2.gd`、`tests/test_fishing_p3.gd`：通过，拖钓/P3 回归通过。
- `godot --headless --path . --script tests/test_p6_2_casting.gd`：通过，P6.2 抛投、船钓线长与 O 键行为回归通过。
- `godot --headless --path . --script tests/test_p6_2_5_reel_audio.gd`：通过，卷线器轴、实际线长驱动、音效所有权和一次性成功提示回归通过。
- `godot --headless --path . --script tests/test_p6_1_onboard_activity.gd`：通过，甲板活动和视角回归通过。
- `godot --headless --path . --editor --quit`：导入和脚本注册完成；显示仓库已有的两组极地帆船 translation UID 重复警告及退出时一个 ObjectDB 泄漏警告。
- `git diff --check`：通过。

Headless P6.3.1 自动收鱼期间，Godot Dummy Renderer 另输出 `material is null` 和一个 Dummy Shader RID 泄漏诊断，但该集成测试所有断言均通过。需要在真实渲染器中复核这两个渲染后端诊断。

## F3 船钓视角问题复核

复核确认，旧的 `FishingPlayerPanel._is_activity_active()` 把共享 Encounter 的任何 `HOOKED/RETRIEVING` 状态都当成拖钓。测试鱼触发船钓中鱼后，该面板发出 `activity_state_changed(true)`，`BoatHUD` 随即开启拖钓杆侧视角并显示固定拖钓杆。这是共享活动状态被错误归类，不是测试鱼调用了拖钓中鱼流程。

现已将拖钓活动判断限定为真正的 `TROLLING` 状态，或 `fishing_method == "trolling"` 的搏鱼/展示过程。船钓自然咬钩与 F3 测试鱼都保持船钓第一人称，固定拖钓杆隐藏，手持鱼竿保留。集成测试分别覆盖自然中鱼与点击 F3 测试按钮后的状态。

## 验收边界与限制

Forward+ 实际视觉验收 **NOT RUN**：本轮没有真实游戏窗口截图或目视确认。因此浅水鱼模型在水下的可见度、转向观感、竿尖受力幅度、出水视觉和实际音量仍需人工检查。F3 测试只隔离了自然鱼群 Authority 种群；因为当前项目没有独立的持久库存/经济层，测试结果会走会话级结果展示，不写入一个尚不存在的隔离存档系统。
