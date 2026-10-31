# Fishing P4.3a 实施摘要

## 改动

- 在现有 `FishFinderDisplay` / `SonarPlot` 增加会话级 Gain 与 Range 状态，没有新增传感器或管理器。
- Gain 有 Auto、Manual 两种模式；手动默认 50%。滑块映射只用于绘制回波亮度/可见度，不改写 Echo 字典或 `FishFinderSensor` 历史。
- Auto Gain 在最近 12 秒的有效回波强度中取中位数，以固定参考强度估计 35–75% 的目标 Gain，再以扫描运行时间和 3 秒平滑常数过渡。空扫描保持当前值，不把窗口内最强回波拉满。
- Manual Gain 使用单调的强度曲线、弱信号门限和透明度映射；0 强度始终不画回波。0.08 级别的弱回波在默认 Auto 下有明显高于低 Gain 的显示强度。
- Depth Range 有 Auto、Manual 模式。Auto 复用原有 5/10/20/30/50 m 档位与升档立即、降档迟滞逻辑。手动模式固定显示玩家选择的档位；超出范围的鱼群回波与底部回波被裁掉。
- Auto 状态在 Manual 模式期间仍根据真实扫描更新，切回 Auto 时直接恢复最新自动档位。切换不会清空历史或重新扫描。
- 展开鱼探仪底部提供两行 Gain/Range 控件；迷你模式只在标题/量程标注简短模式状态。自动模式禁用对应的手动控件。
- F3 状态增加 Gain 模式、手动值、当前有效显示 Gain、量程模式和当前显示量程。
- F3 声呐预览继续使用独立历史；预览开始/停止不改变真实历史或会话显示偏好。

## 主要文件

- `scripts/fish_finder_display.gd`
- `scripts/fishing_debug_panel.gd`
- `resources/translations/fish_species.csv` 及导入生成的英文/简体中文资源
- `tests/test_fishing_p4_3a.gd`

没有修改 `FishFinderSensor` 的探测几何或原始回波强度；P2/P3 Authority、概率、数量和 RNG 不在显示控制路径中。
