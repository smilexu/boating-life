# Fishing P4.2 — 最终审查

## 交付结论

已完成玩家可操作的实时 2D CHIRP 风格鱼探仪界面。界面绘制来自 P4.1 的同一真实传感器历史，保持 P2 Authority 鱼群及钓鱼逻辑只读。

## 使用方式

- 游戏内右下角默认显示迷你鱼探仪。
- 标题栏 `+` 展开、`−` 收起；`×` 隐藏，右下角打开按钮重新显示。
- 展开时游戏不暂停，仍使用当前扫描历史。O 键相机循环与 F3 保持独立。
- 状态区显示探头至底部距离（有效时）、船速 kn、显示量程；图表深度轴同样以探头为 0 m。

## 功能与验证

- 海底回波来自有效 P4.1 底部深度记录；无效数据显示 `--` 并打断海底轮廓。
- 鱼群亮斑来自每列实际 Authority school 聚合回波，不显示鱼种或精确数量；强度和显示宽度只控制图形。
- 新扫描列在右侧，历史按实际运行时扫描时间向左排列，显示最近约 60 秒。
- 自动量程采用 5/10/20/30/50 m 与 3 秒/70% 降档迟滞；50 m 是显示范围，不是传感器探测范围。扫描频率和几何未改。
- F3 显示 UI 模式、可见列数、量程、最近回波数、底部有效性和扫描时间。
- 英文与简体中文界面文案通过针对性测试。
- P4.2、P4.1、P2 Headless 测试及 headless editor import/parse、`git diff --check` 均 PASS。详见 `TEST_RESULTS.md`。
- 本机 M2 Pro Godot Forward+ 中已目视检查迷你和展开模式。该测试位置未观察到鱼群回波，因此真实亮斑的屏幕效果标为未完成视觉检查；Windows 和多宽高比未运行。

## 修改范围

P4.2 主要文件：

- `scripts/fish_finder_display.gd`
- `scripts/boat_hud.gd`
- `scripts/fishing_debug_panel.gd`
- `resources/translations/fish_species.csv`
- `resources/translations/fish_species.en.translation`
- `resources/translations/fish_species.zh_CN.translation`
- `tests/test_fishing_p4_2.gd`

P4.1 传感器及数据源在此工作区之前已完成并保留，本轮没有重写。没有修改 P2 中鱼概率、Authority population、学校生成、船舶运动或天气。

## 已知限制与下一步

1. P2 回波为学校聚合点，`echo_width_m` 是显示代理；实际屏幕呈现不是每条鱼的位置或真实水声测量。
2. 有效真实回波下的 Forward+ 截图、窗口尺寸/多宽高比、Mac/Windows 键鼠组合仍需人工验收。
3. 本阶段没有做性能基准。图表重绘的规模受 P4.1 有界历史和实际回波数限制。
4. 下一步最有效的画面确认是在 F3/P4.1 支持的真实学校位置手动扫描，观察展开图中真实亮斑与海底的相对深度，并核对不同船速下历史向左滚动；无需修改鱼群或概率。
