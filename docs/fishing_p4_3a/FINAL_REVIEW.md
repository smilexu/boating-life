# P4.3a 最终审查

## 玩家操作

迷你鱼探仪继续显示水深、船速、量程和声呐图，并在标题/量程处标明 Auto 或 Manual 状态。点击展开后，在声呐图下方设置：

- **Gain**：Auto / Manual。Manual 下滑块范围 0–100%，默认 50%；Auto 下显示当前有效 Gain 百分比。
- **Range**：Auto / Manual。Manual 下拉选择 5、10、20、30 或 50 m。

设置随当前 `FishFinderDisplay` 实例保留，收起、隐藏重开、切换活动船和开始/停止 F3 预览都不会重置。新进程默认 Auto Gain + Auto Range。

## 显示与数据边界

Gain 对原始 `echo_strength` 做单调显示映射，仅影响鱼群回波的可见强度和弱回波门限。Auto Gain 参考最近 12 秒的有效回波中位数，目标被限制在 35–75%，采用扫描运行时钟平滑；空扫描保持当前值。海底回波维持原有清晰度，不受 Gain 影响。

Range 仅控制显示坐标范围。Auto 使用原有迟滞与档位，Manual 固定档位并裁切范围外回波；底部超过手动量程时不会伪装成量程边缘的底部线。50 m 仍只是显示档位，不改变 P4.1 的最大 45 m 探测深度。

F3 诊断显示 Gain mode、Manual Gain、当前有效 Gain、Range mode、手动档位和当前量程。Gain/Range 不写入玩家存档，不修改扫描器、Authority 鱼群、P2 RNG 或捕获概率。

## 验收状态

- 新增 P4.3a 自动化测试：PASS。
- P4.1、P4.2、P4.2.2 场景及 P2/F3 直接相关回归：PASS。
- Godot Headless 编辑器导入/脚本解析、`git diff --check`：PASS。
- Forward+ 实际布局、弱回波真实显示观感及鼠标操作：NOT RUN。

因此，数据映射和控制行为已通过自动检查；玩家屏幕上的控件间距和 0.08 回波最终可读性仍需在 Forward+ 运行画面确认。新代码不会注入当前已运行的游戏进程，需由玩家重新载入项目后检查。
