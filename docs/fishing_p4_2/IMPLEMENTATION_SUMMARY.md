# Fishing P4.2 — 实施摘要

## 状态

P4.2 的玩家鱼探仪界面已实现。显示层复用 P4.1 的 `FishFinderSensor` 与历史快照，不创建第二个传感器，也不对 Authority 鱼群进行额外查询。

## 已实现

- 在 `scripts/fish_finder_display.gd` 新增 `FishFinderDisplay`。使用 Godot `Control` 和 `_draw()` 绘制深色声呐图、时间/水深网格、连续海底回波及聚合鱼群亮斑。
- 显示最近 60 秒历史；扫描时间来自 `scan_runtime_seconds`，新列映射到右边、旧列映射到左边。扫描仍由 P4.1 按约 3 Hz 产生，界面最多约 18 Hz 重绘，不补造扫描列。
- 海底与鱼群目标深度都以换能器为零点：使用 `bottom_depth_below_transducer_m` 和 `target_depth_below_transducer_m`。标题明确标注“探头至海底”，避免把它说成水面下水深。
- 只绘制 `bottom_valid` 的海底数据。无效列造成海底轮廓缺口；实时水深显示 `--`。有效扫描但没有鱼群时显示空回波状态；尚无扫描和传感器不可用分别显示等待/不可用。
- 鱼群仍按 P4.1 的每校一条聚合回波显示，不展示鱼种或精确数量。强度控制亮度、`echo_width_m` 显示代理控制亮斑大小；同一学校只在相邻记录间隔不超过 1 秒时绘制淡连接线。
- 自动显示量程使用 5/10/20/30/50 m 档位，包含底部和余量后选择最小档。只在有效底部数据上调整；升档立即生效，降档需低于当前量程 70% 并持续 3 秒。50 m 是图表范围，P4.1 传感器的最大水深仍是 45 m。
- 迷你视图位于右下角；`+` 展开、`−` 收起、`×` 隐藏；隐藏后 Boat HUD 的打开按钮可重新显示。展开图约占视口 60%×62%，尺寸跟随当前 Viewport。
- 展开时临时把承载 Boat HUD 的 CanvasLayer 提至 90，避免被普通诊断层遮挡；收起、关闭或节点退出时恢复原层级。项目菜单层 100 仍高于鱼探仪。
- `scripts/boat_hud.gd` 创建界面并传入现有鱼资源管理器及船速来源。速度复用船舶 `speed_mps` 并换算为 kn。`scripts/fishing_debug_panel.gd` 保留既有传感器诊断并增加显示模式、列数、量程、回波数、底部有效性和扫描运行时。
- 在 `resources/translations/fish_species.csv`、`fish_species.en.translation` 和 `fish_species.zh_CN.translation` 增加英文与简体中文界面文案。

## 操作

- 游戏运行后右下角显示迷你鱼探仪。
- 按面板标题栏 `+` 展开，`−` 收起；`×` 隐藏，右下角打开按钮重新显示。
- 展开/收起不暂停游戏，不需要新快捷键；O 视角循环和 F3 诊断保持原有输入。

## 修改文件

- `scripts/fish_finder_display.gd`、对应 `.uid`
- `scripts/boat_hud.gd`
- `scripts/fishing_debug_panel.gd`
- `resources/translations/fish_species.csv`
- `resources/translations/fish_species.en.translation`
- `resources/translations/fish_species.zh_CN.translation`
- `tests/test_fishing_p4_2.gd`、对应 `.uid`

P4.1 原有传感器及测试文件在本工作区仍是先前阶段的未提交改动；P4.2 没有改变其扫描算法或 P2/P3 钓鱼逻辑。

## 限制

当前 P2 Authority 只提供学校级锚点、聚合鱼数和活动水层；界面不能也不会绘出单条鱼的位置。鱼群大小是声呐显示代理。此次 Forward+ 检查中没有真实回波落入当前视野，因此画面已验证海底与空扫描状态，但鱼群亮斑的实际屏幕观感仍需在有有效回波的场景确认。Windows 和不同显示器宽高比未实际验证。
