# Fishing P3.2 实施摘要

状态：PASS（Headless 功能通过；Forward+ 视觉验收未运行）

## 目标

- 让真实 P2 中鱼自动经过 retrieval 与 settlement，不需要 F3 手动推进。
- 增加不创建 PendingCatch、不调用 P2 结算、不扣除学校数量的 F3 模拟搏鱼。
- 两种入口共用 FishingRodSystem 的 P3.1 状态机和视觉 rig。
- 在 F3 增加鱼种/长度、开始/停止/重播、暂停、速度和阶段跳转，并把旧 P2 操作收进高级折叠区。

## 实际修改

- `scripts/fishing_rod_system.gd`：加入 `REAL_CATCH` / `DEBUG_SIMULATION` 演出来源；模拟入口、停止、重播、暂停、0.5×/1×/2×、阶段跳转和动态阶段起点。真实 retrieval 与 settlement 按 catch ID 自动推进且各最多请求一次。
- `scripts/fishing_encounter_system.gd`：模拟预览期间暂停 P2 候选采样和 encounter 时间累积，保持真实拖钓状态、hazard 和 RNG 不变；恢复时从新的游戏时间基准继续。
- `scripts/fishing_rod_rig.gd`：模拟暂停与本地时间倍率同步应用于鱼竿弹性、鱼线、卷线器和局部水花；清理时隐藏残留水花并复位临时鱼。
- `scripts/fishing_debug_panel.gd`：新增模拟鱼种、体长、重量预览、seed、播放控件及来源状态；原 P2 手动控制收进默认折叠的 Advanced P2 diagnostics。
- `scripts/fishing_player_panel.gd`：为调试模拟状态提供本地化状态名称。
- `resources/translations/fish_species.csv`：补充模拟操作和状态的 English / 简体中文 key。
- `tests/test_fishing_p3.gd`：真实 PendingCatch 存在时断言模拟入口被拒绝。
- `tests/test_fishing_p3_2.gd`：新增零船速、无有效鱼群、五阶段、隔离、播放控制和 UI 针对测试。

## 后续修复：F3 模拟鱼种下拉框为空

- 实际原因：主场景中 `BoatHUD` 比后续的 `FishResourceManager` 节点更早创建 F3 Fishing 面板。面板初次读取时鱼种 Profile 尚未注册；后续刷新只更新了拖钓系统，没有重新填充模拟鱼种。
- `scripts/fishing_debug_panel.gd` 现在会在系统刷新时检查鱼种列表变化，资源就绪后填入海鳟和针鱼，并保留玩家当前选择。资源尚未就绪时显示“不可用”，不再留空。
- 没有可用物种时禁用模拟按钮；点击处理器也会拒绝空 ID。鱼种 Profile 可用后，按钮和下拉框立即恢复可用，重量预览从实际 Profile 计算。
- `tests/test_fishing_p3_2.gd` 增加了复现 HUD 先于鱼资源注册的初始化顺序、鱼种列表恢复、长度联动，以及通过 F3 模拟/停止按钮启动并清理演出的检查。

## 实施结果与决策

- 模拟演出直接复用 FishingRodSystem，不创建临时 PendingCatch、FishingCatchResult 或另一套动画控制器。
- F3 模拟在没有鱼群和船速时可用。鱼种来自现有 `FishSpeciesProfile`，支持 `sea_trout` / `needlefish`；默认长度为 65 / 60 cm，长度按物种自然范围钳制，重量仅显示预览。
- 模拟不创建 P2 PendingCatch / CatchResult、不调用 settlement、不修改 Authority population，也不消耗 P2 encounter RNG。为防止真实 hook 抢用同一根杆，模拟时暂停 encounter 采样；开始前若已有真实 pending catch 则拒绝模拟。
- 当前搏鱼动画使用确定性曲线，不进行运行时随机抽样。seed 被保存到演出上下文和 replay 参数；同一鱼种、体长和 seed 的回放一致。
- 模拟时间倍率只作用于本地 presentation delta 和 rig 动画，不更改 `Engine.time_scale`、船舶物理、天气或 P2 游戏时间。
- P3.1 中真实 hook 自动经过 Hook Strike → Fish Struggle → Retrieval → Surface & Landing；约 18 秒自动调用 P2 `begin_retrieval()`，约 48 秒自动请求 `complete_retrieval(catch_id)`，成功后展示并在 56 秒附近恢复拖钓。P3.2 核对并回归此现有流程，未以 F3 手动按钮作为正常流程依赖。
- 五阶段 seek 使用当前导出时长动态计算起点，并重建阶段、杆负载、鱼线/卷线器、鱼体阶段与 Fight Camera 焦点；跳转仅适用于模拟，不调用 P2 settlement。
- 停止模拟会清除临时鱼、杆体负载、卷线器旋转、鱼线、水花和 Fight Camera 状态，并恢复仍然有效的真实拖钓状态。切船和退出树时也会释放模拟的 P2 暂停标记。
- F3 高级 P2 操作在模拟播放时禁用；正常 F3 模拟区域位于面板上方，原有真实诊断 API 保留。

## 已验证

- `tests/test_fishing_p2.gd`、`tests/test_fishing_p3.gd`、`tests/test_fishing_p3_1.gd`、`tests/test_fishing_p3_2.gd` 全部 `failures=0`；P2/P3/P3.1 历史断言数为 44/39/53，P3.2 本轮扩展至 85 项。
- Headless 场景/脚本导入可解析；`git diff --check` 通过，详见 `TEST_RESULTS.md`。
- 未运行 Forward+ 交互画面检查；当前 UI automation 返回 `cgWindowNotFound`，因此鱼体、鱼线、水花和 Fight Camera 构图仍需图形界面人工确认。
