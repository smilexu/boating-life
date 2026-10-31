# Fishing P3.3c.4 — 最终审查

## 结果

悬挂鱼体从持续双波 S 曲线改为后段主导的 C 型爆发：头部权重低、主弯落在中后段、尾击限定于尾部。反向爆发由配置脉冲切换方向；S 曲线混合上限降到 0.18，并只在脉冲边沿短暂启用。额外横摆由同一脉冲的方向和强度驱动，最高 15°，稳定阶段逐渐只剩低幅摆动。鱼嘴继续钉在线端。

海鳟采用更大的中段/尾部比例，针鱼维持较快频率和较小比例。P2、56 秒时序、悬挂位置、鱼竿/鱼线、HUD 与 Fight Camera 均未修改。

## 验收

- 针对性 Headless 测试：**PASS**。
- `git diff --check`：**PASS**。
- Forward+ 实际画面：**NOT RUN**。仍需在游戏中观察海鳟与针鱼的 C 弯、尾部抽打和同步横摆是否自然；本轮不宣称视觉验收完成。

## 后续可调参数

- `hanging_body_wriggle_amplitude_ratio`、`hanging_tail_wriggle_amplitude_ratio`、频率及 `hanging_body_wriggle_pulses`：各鱼种动作。
- `hanging_burst_sway_impulse_degrees`、`hanging_sway_max_degrees`：挣扎横摆输入与上限。
- Shader 内 `front_weight`、尾部 `tail_gate`、S 混合上限：动作分区曲线。
