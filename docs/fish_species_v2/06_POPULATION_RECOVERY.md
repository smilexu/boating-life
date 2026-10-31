# P1.5 最小鱼群数量恢复

**状态：**PASS  
**阶段目标：**为鱼群已扣减的数量增加基于游戏世界时间的指数恢复；不连接捕鱼、不改变未消耗学校，保留零人口学校身份。  
**预计修改：**`scripts/fish_school_state.gd`、`scripts/fish_local_authority.gd`、`scripts/fish_authority_adapter.gd`、`scripts/fish_resource_manager.gd`、`tests/test_fish_population_recovery.gd`。  
**验收：**扣减后恢复缓慢且不超过各校基线；未耗损群体不变；零人口学校可恢复；恢复使用 `WorldTimeManager` 游戏时间、离屏照常；相同 seed/config/time 操作可复现；旧学校快照 schema 被明确拒绝。

## 设计边界

- 使用现有 `WorldTimeManager.state.day_cycle_index` 与 `cycle_seconds` 组合绝对游戏时间，不读渲染帧计数或墙钟时间。
- 在现有分批学校更新路径中恢复，避免每个渲染帧额外遍历全量学校。
- 学校状态只增加基线人口、游戏时间戳和小数恢复余量；不建立与学校数重复的全局种群表。
- 采用整数人口加 `[0,1)` 的非负小数余量，避免零人口学校因取整永远无法恢复第一条鱼。
- 学校快照增加恢复字段后，将 Authority snapshot schema/layout 升级到 3/5，学校 schema 升级到 3；旧开发快照不做隐式升级。

## 阶段完成记录

### 2026-10-30 实施前修订

- 恢复速率定为全局 `0.006 / 游戏小时`，相当于连续状态下约 116 游戏小时恢复一半缺口；这是游戏化首值，不是生物学恢复率。
- 恢复仅在 Authority 既有 8 秒批处理里访问学校，不引入逐帧全量种群遍历；仅处理低于基线的学校。
- 小数余量用 `[0, 1)` 表示连续恢复进度，捕捞扣减按整数个体从连续进度中扣除；人口达到整数 1 后从 `depleted` 转为 `available`。
- 世界时间倒退/日期管理跳转只重置该校时间锚点，不倒扣种群，也不一次性积累时间差。
- 下一步修改 `FishSchoolState`、Authority adapter/manager，并通过模拟扣减与世界时间推进测试。

### 2026-10-30 完成记录

- `FishSchoolState` 新增 `baseline_population`、`last_population_update_game_time_seconds` 与 `recovery_fractional_population`。恢复曲线采用 `K - (K - N) * exp(-0.006 * elapsed_game_hours)`，向下取整为实际数量并保存小数余量；距基线小于 `1e-6` 时收敛到精确整数基线，不超过基线。
- `FishResourceManager` 从 `/root/WorldTimeManager.state` 读取 `day_cycle_index × 86400 + cycle_seconds`，传给 Authority 初始化、更新和人口扣减 API。游戏时间暂停时没有恢复；倒退时仅重置学校时间锚，不倒扣或发放额外鱼。
- 恢复放在现有每 8 秒学校分批更新里，只访问低于 baseline 或仍有小数余量/耗尽状态的学校；没有新增逐渲染帧全量遍历。零人口学校留在 Authority 和空间索引中，整数 population 恢复到 1 后转回 `available` 并重新出现在活动快照中。
- 模拟扣减测试验证：120 游戏小时符合指数式进度；未耗损学校数量不变；回拨时间不增减数量；新时间锚向前运行继续恢复；长时间恢复到 baseline 后不超量；恢复字段可往返快照。
- Authority snapshot 当前版本为 schema 3 / layout 5，单校状态 schema 3。旧学校 schema 2 和 authority schema 2/layout 4 明确拒绝，不做静默补默认值转换。游戏目前没有独立的鱼类存档文件，所以不需要清理玩家文件。
- 恢复仅为未连接捕捞扣减的底层机制；当前不实现捕鱼、不触发真实中鱼或持久化渔获。
- 验证命令：`godot --headless --path . --script res://tests/test_fish_population_recovery.gd`，14 项 PASS，`failures=0`。Headless renderer 在退出时仍打印既有 DummyShader RID leak warning。

**P1.5 状态：PASS。**
