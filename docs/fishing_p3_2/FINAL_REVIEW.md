# Fishing P3.2 最终审查

## F3 模拟入口后续修复

- 修复 F3 Fishing 页面早于 `FishResourceManager` 完成 Profile 加载时，下拉列表永久保持空白的问题。
- Profile 注册后会自动补齐物种列表；无物种时显式显示不可用并禁用启动，避免按钮点击后因空 Species ID 悄然失败。
- 通过 `tests/test_fishing_p3_2.gd` 验证了海鳟/针鱼选择、海鳟/针鱼体长联动、模拟按钮启动与停止。Headless 自动化通过；真实 Forward+ 画面尚未检查。

状态：**自动化功能 PASS；Forward+ 画面验收 NOT RUN**

## 已完成

### 真实拖钓流程

- 真实 P2 `fish_hooked(PendingCatch)` 由 `FishingRodSystem` 接入已有 P3.1 演出。
- Hook Strike、Fish Struggle、Progressive Retrieval、Surface & Landing 和 Catch Presentation 自动推进，不要求开发者点击“开始收线”或“完成收线结算”。
- P3.1 已有的 18 秒 retrieval、48 秒结算、56 秒收尾时序经 P3 自动化集成测试验证。settlement 继续通过 P2 `complete_retrieval(catch_id)` 执行；Catch ID 和天然体长保持一致，取消不发放捕获。
- F3 原手动 P2 操作仍可在折叠的 Advanced P2 diagnostics 中使用，正常拖钓流程不依赖它们。

### F3 模拟中鱼

- Fishing 面板新增模拟区域：选择海鳟/针鱼、设置体长和动画 seed、查看估算重量，开始、停止、重播、暂停/继续、0.5×/1×/2×播放和跳转五阶段。
- 不要求真实鱼群或船速；没有有效候选、零船速的自动化夹具中可直接播放。
- 模拟与真实捕获共用 `FishingRodSystem` 的阶段更新、`FishingRodRig`、临时鱼模型和 Fight Camera；没有复制一套搏鱼动画。
- 模拟来源是 `DEBUG_SIMULATION`。不会创建 `FishingPendingCatch` / `FishingCatchResult`，不调用 P2 settlement，不改变 population、库存或 P2 RNG。
- 现有真实 pending catch 会阻止模拟启动。模拟期间若原本正在真实拖钓，会保留 P2 TROLLING 状态并冻结 encounter 时间采样；退出模拟后从当前世界时间继续，避免预览期间真实 hook 争用鱼竿。
- 预览体长按现有物种 natural body-length range 钳制；重量使用 profile 中已有估算公式，仅供调试预览。
- 演出曲线目前是确定性的，没有运行时随机抽样；相同鱼种、长度和 seed 回放相同。seed 被保存并显示，方便后续加入确定性变化。

### 清理与 UI

- 停止或完成预览会清除临时鱼、鱼竿负载、鱼线、卷线器、局部水花和 Fight Camera 状态。
- 停止预览时按 P2 当前状态恢复真实拖钓；若玩家在预览期间停止拖钓，不会错误恢复旧的 TROLLING 状态。
- 五阶段跳转根据实际配置时长重新设置阶段、负载、线长、卷线器、鱼体阶段和相机焦点；结算阶段是预览，不触发真实成功事件。
- 新界面文字已添加英文和简体中文翻译，旧 P2 高级诊断仍可访问。

## 修改文件

- `scripts/fishing_rod_system.gd`
- `scripts/fishing_encounter_system.gd`
- `scripts/fishing_rod_rig.gd`
- `scripts/fishing_debug_panel.gd`
- `scripts/fishing_player_panel.gd`
- `resources/translations/fish_species.csv`
- `tests/test_fishing_p3.gd`
- `tests/test_fishing_p3_2.gd`
- 本目录下 `IMPLEMENTATION_SUMMARY.md`、`TEST_RESULTS.md`、`FINAL_REVIEW.md`

## 测试与验收

- P2、P3、P3.1、P3.2 Headless 定向测试均通过，明细和命令见 [TEST_RESULTS.md](TEST_RESULTS.md)。
- Headless 测试证明逻辑状态、P2 隔离、物种/长度上下文、阶段时序和 UI 控件创建；它不能证明真实 3D 画面质量。
- Forward+ 视觉检查未运行，因为当前桌面自动化无法获取 Godot 窗口。仍需实际运行游戏检查临时鱼 GLB 的显示、线与船体穿插、海鳟跃水/洗鳃动作是否可见、水花位置以及 Fight Camera 构图。

## 游戏内验证方式

1. 使用更新后的主游戏运行版本，打开 F3 → Fishing。
2. 在“模拟中鱼 / 动画调试”中选择“海鳟”，体长保持 65 cm，点击“模拟中鱼”。无需找到鱼群，也无需移动船。
3. 使用暂停、0.5×/2×、重播和“跳转阶段”检查水面与出水阶段；需要完整流程时保持 1× 等待约 56 秒。
4. 检查真实拖钓时，使用正常拖钓入口开始航行；真实中鱼后无需在 F3 点收线或结算。

P3.2 完成后停止；没有开始 P3.3 或 Fish Finder UI 工作。
