# Fishing P4.1 — 测试结果

Godot：`4.7.2.stable.official.ed1daf0bf`。

| 检查 | 结果 | 实际结果 |
|---|---|---|
| `godot --headless --path . --script res://tests/test_fishing_p4_1.gd` | PASS | exit 0，`[FISHING_P4_1] failures=0`。验证水深/锥形几何、真实学校聚合与确定性强度、无效学校数据过滤、空列、历史留存及有界容量、停船 3 Hz 扫描、活动船切换、无效海图、空间索引查询。 |
| `godot --headless --path . --script res://tests/test_fishing_p2.gd` | PASS | exit 0，`[FISHING_P2] failures=0`。包含真实 FishResourceManager Authority 回波、声束边界、容量、鱼群 Authority revision 不变、Encounter RNG 不变，以及 P2 拖钓/结算回归。 |
| `godot --headless --editor --path . --quit` | PASS | exit 0，项目扫描、FishFinderSensor 类注册和编辑器资源加载完成。无渲染设备的 headless editor 在退出时报告 1 个 ObjectDB instance leak；未见解析错误。 |
| `git diff --check` | PASS | 无空白或补丁格式错误。 |
| Forward+ / P4.2 声呐画面验收 | NOT RUN | 本阶段只交付数据接口，没有制作最终声呐画面；未声称完成图形验收。 |

P2 与 P4.1 场景测试均会出现已有 BathymetryManager fixture 警告：测试未给海图管理器指定 ShaderMaterial，因此海水色调功能保持禁用；其数据采样及断言正常。该警告不是声呐深度回退，也没有使用固定深度代替采样。
