# Fishing System P3.1 — 最终审查

## 状态

**代码和 Headless 集成验证完成；玩家可见的 Forward+ 验收仍待人工完成。** 本轮没有修改 P2 中鱼算法、鱼群资源或船舶动力学。

## 完成内容

- 56 秒可配置演出：Hook Strike 3 s、Fish Struggle 15 s、Progressive Retrieval 22 s、Surface & Landing 8 s、Catch Presentation 8 s。
- 两鱼种使用独立 `FishingFightProfile`；增加明显受力、离散挣扎/反向放线、连续靠近、动态水面出水与轻量固定拓扑水花。
- 两船竿尖弯曲目标为 0.96 m，可见放线长度为 9 m；竿体、导环与鱼线拓扑不逐帧重建。
- 单一既有 `BoatFollowCamera` 加入临时 `fight_camera`，并沿用 O 键控制；自动切入默认开启，收线进度平滑推动注视点向船尾近水面移动，镜头冲击可按 Profile 关闭或调弱。
- F3 新增搏鱼状态诊断；Catch Presentation 与玩家提示均使用 8 秒展示时间。
- P2 hook ID 保持贯穿演出；18 秒开始调用 retrieval，48 秒请求一次正式结算，取消/结算失败不显示成功渔获，成功展示后恢复拖钓。鱼体长固定来自 PendingCatch / CatchResult。
- 后续针对画面反馈做了修正：卷轴绕水平横轴转动、竖直轮盘面带辐条；海鳟先下潜再跃出水面，之后明显侧翻洗鳃并快速提升；Fight Camera 注视点从远处水面移近到鱼与船尾之间。
- 本轮进一步把两船鱼竿挂点上移 0.20 m、修正收线方向，并把鱼线入水点移到竿尖后方、让线端跟随船尾外侧挣扎中的鱼头。收线中的鱼按 WaveSampler 逐步贴近并露出水面。具体可调与写死行为见 [ANIMATION_LOGIC.md](ANIMATION_LOGIC.md)。
- 根据截图再次修正了线半径重复缩放，并让鱼从水面沿短弧落到船型配置的甲板位置；结算展示不再把鱼挂在竿上方，结果文字继续由 HUD 呈现。

## 修改文件

- `scenes/Boat.tscn`
- `scripts/fishing_rod_system.gd`
- `scripts/fishing_rod_rig.gd`
- `scripts/fishing_rod_mount_profile.gd`
- `scripts/fishing_fight_profile.gd`
- `scripts/boat_follow_camera.gd`
- `scripts/fishing_debug_panel.gd`
- `scripts/fishing_player_panel.gd`
- `resources/fishing/rod_mounts/starter_cargo_boat.tres`
- `resources/fishing/rod_mounts/nordic28.tres`
- `resources/fishing/fight_profiles/sea_trout.tres`
- `resources/fishing/fight_profiles/needlefish.tres`
- `resources/translations/fish_species.csv`
- `tests/test_fishing_p3.gd`
- `tests/test_fishing_p3_1.gd`
- `docs/fishing_p3_1/IMPLEMENTATION_SUMMARY.md`
- `docs/fishing_p3_1/CAMERA_INTEGRATION.md`
- `docs/fishing_p3_1/TEST_RESULTS.md`
- `docs/fishing_p3_1/FINAL_REVIEW.md`

## 验证结论

- P2、P3、P3.1 针对性 Headless 测试：PASS。
- 资源与项目场景扫描：PASS；保留与本任务无关的重复 translation UID 警告及编辑器退出 ObjectDB 泄漏提示。
- 针对卷轴方向和海鳟动作修正后的 P3.1 与 P3 Headless 测试：PASS。
- 本轮竿架/卷线器/鱼线回归测试：P3.1 Headless PASS；测试验证坐标逻辑和事件绑定，不能替代 Forward+ 画面。
- 实际 Forward+ 进程启动：PASS；Metal 设备日志识别为 Apple M2 Pro。
- 56 秒连续动画、鱼体运动、水花和 Fight Camera 画面：**NOT RUN**。运行窗口未能通过当前屏幕自动化从编辑器中取得，因此不能宣称画面验收通过。
- Windows：NOT RUN。

## 已知限制与人工验收

1. starter cargo boat 与 Nordic 28 的镜头偏移和注视点已经重新配置，竿架也上移 0.20 m；仍需实际游戏画面确认栏杆是否不再穿模、加粗鱼线能否在远处读清、两条船的甲板落点是否合适，以及鱼是否在船尾左右挣扎、跃水/洗鳃是否能看清。
2. 当前无可复用相机碰撞处理接口，P3.1 没有加入新的碰撞系统。
3. 使用 F3 模拟时选择 Sea Trout；前约 23 秒鱼身隐藏。要直接检查跃水/洗鳃，可跳转到 Surface & Landing 阶段，观察跃水和侧翻。针鱼配置不启用海鳟式跃水/洗鳃。0.96 m 弯曲和 9 m 视觉线长是配置目标；结算鱼现在落到配置的甲板位置，不再上升到竿上方。代码断言不能代替视觉判断。
4. 新启动的 Forward+ 游戏进程仍在运行，未被自动关闭。F3 面板可检查阶段/剩余时间/竿负载/线状态/鱼体阶段/相机模式；使用 F3 的有效 force-hook 后用 O 检查 Fight Camera。
5. 工作区原有的 `scripts/fishing_rod_system.gd` 未纳入 Git 跟踪，无法从版本历史恢复或比较。本次该控制器按当前 P2/P3 API 和测试重新整理；尽管相关 P2/P3/P3.1 测试通过，仍建议在合并前人工复核该文件与原开发分支的差异。
