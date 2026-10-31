# Fishing System P3.1 — Fight Camera 接入

## 现有坐标与控制器

- O 键仍由 `scripts/boat_follow_camera.gd` 的既有 `god_view_toggle` 输入处理；没有增加另一套输入监听或 Camera3D。
- 当前船艏沿船体局部 `-Z`，船尾沿 `+Z`。鱼竿挂载点位于船尾；相机位置使用负局部 Z（向船艏/船内），注视点使用正局部 Z（船尾外的水面）。
- `FishingRodSystem` 根据 `BoatController.vessel_mode_changed` 选择当前船型的 FishingRodMountProfile，并把活动挂点注册给 `BoatFollowCamera`。切船时更新锚点；没有挂载配置时从 O 循环移除 Fight Camera。

## 两船初始配置

| 船型 | 相机偏移（挂点局部坐标） | 注视点（挂点局部坐标） | FOV | 跟随阻尼 | 冲击强度 |
|---|---|---|---:|---:|---:|
| starter cargo boat | `(0.45, 1.05, -1.55)` m | `(0, -0.7, 1.9)` m | 55° | 6.0 | 0.035 m |
| Nordic 28 | `(0.5, 1.2, -1.8)` m | `(0, -0.34, 1.3)` m | 55° | 6.0 | 0.035 m |

这些是起始构图值，尚未通过实际 Forward+ 画面确认遮挡或取景边界。

两个船型默认都将注视点按收线进度最多偏移 `(0, -0.15, -0.45)` m。挂点正 Z 指向船尾，因此负 Z 调整会把目光从远处船尾水面移向靠近船的鱼/水花区域；相机插值继续使用船型跟随阻尼，不读取鱼模型的逐帧位置。该构图调整尚未经过 Forward+ 人眼验收。

## O 键与自动切换

1. 平时可选视角仍为 Follow → God。
2. 收到真实 P2 `fish_hooked(PendingCatch)` 时，系统保存当前普通视角并临时开放 Fight Camera；默认 `auto_switch_to_fight_camera = true`，平滑切入。
3. 演出期间 O 键仍循环。玩家一旦离开 Fight Camera，不会被自动切回。
4. 演出结束时：若玩家仍在 Fight Camera，则恢复 hook 前保存的视角；若玩家已选其他普通视角，则保留玩家选择。
5. 取消、停止拖钓、切船或挂点失效时释放当前镜头状态。镜头冲击只在 Fight Camera 当前启用时响应 Hook/挣扎脉冲，可在挂载 Profile 中设为零。

## 未验证项

- Headless 测试验证 O 循环状态、自动恢复、玩家手动离开、关闭自动切入、切换挂点和无挂点行为。
- 由于本轮无法从屏幕自动化中取得运行中的游戏窗口，两个船型的实际画面构图、相机遮挡、平滑观感和 HUD 遮挡均为 **NOT RUN**。
- 当前没有相机碰撞/遮挡处理 API；需人工检查相机是否进入船舱/顶棚或裁切竿尖、鱼和水花。
