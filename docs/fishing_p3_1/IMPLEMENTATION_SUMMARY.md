# Fishing System P3.1 — 实施摘要

## 目标与状态

将 P3 的短收线演出延长为分阶段自动搏鱼，并把临时搏鱼镜头接入现有 O 键循环。P2 仍负责有效学校筛选、PendingCatch、人口扣减和 CatchResult。

**状态：实现完成；Headless 针对性验证通过；Forward+ 动态搏鱼画面验收未完成。**

## 实施内容

- `scripts/fishing_rod_system.gd`：新增五阶段 presentation 状态机。默认时序为 3 + 15 + 22 + 8 + 8 秒，总计 56 秒。演出使用自己的渲染帧计时；18 秒后请求 P2 开始收线，48 秒后只请求一次 P2 正式结算，展示 8 秒后恢复拖钓。旧 Catch ID、取消、停止拖钓和结算失败均清理演出，不发放重复渔获。
- `scripts/fishing_fight_profile.gd` 与 `resources/fishing/fight_profiles/{sea_trout,needlefish}.tres`：以 Resource 配置两种鱼的基础竿负载、确定性挣扎脉冲、反向放线、鱼体姿态和水花节奏。海鳟负载较大；针鱼横摆频率和幅度较大。只控制演出。
- `scripts/fishing_rod_rig.gd`：保留 12 段竿、7 个导环和固定拓扑 MultiMesh；增加非线性受力弯曲、受力冲击与阻尼回弹、反向转动卷线器、逐步接近船尾的临时鱼体姿态，以及固定数量低成本水花实例。
- `scripts/fishing_rod_mount_profile.gd`、`resources/fishing/rod_mounts/{starter_cargo_boat,nordic28}.tres`：两船最大竿尖弯曲设为 0.96 m，可见放线长度设为 9 m；后者与 P2 的统计拖钓距离分开。新增每船可配的 Fight Camera 偏移、注视点、FOV、跟随阻尼和微弱冲击强度（默认 0.035 m，可设为零）。
- `scripts/boat_follow_camera.gd`：沿用唯一相机和既有 `god_view_toggle`（O）输入。Fight Camera 仅在演出期间加入 Follow/God 循环。Hook 时默认平滑切入；玩家手动离开后不抢回；演出结束时只有仍在 Fight Camera 才恢复原普通视角。鱼发力脉冲触发轻微阻尼镜头冲击；注视点从竿线方向按收线进度平滑向船尾近水面偏移，不逐帧追踪鱼体。
- `scripts/fishing_debug_panel.gd`、`scripts/fishing_player_panel.gd`、`resources/translations/fish_species.csv`：F3 显示阶段、剩余时间、总进度、杆体负载、线状态/长度、鱼体阶段、镜头模式和自动切入开关；渔获提示时长调整为 8 秒，并补充英文/简体中文显示 key。
- `scenes/Boat.tscn`：接入搏鱼系统、两船挂载配置和两种鱼的搏鱼配置。

## 2026-10-30 画面反馈修正

- `scripts/fishing_rod_rig.gd`：将卷轴转动明确限制在其局部 Y 轴；卷轴支点旋转 90° 后该轴与船体局部横向轴重合，卷轴的圆盘面处于竖直平面。增加六根可见辐条、轮盘侧板和摇柄，使旋转方向能从画面辨认。没有改动钓鱼概率或统计拟饵距离。
- `scripts/fishing_fight_profile.gd`、`resources/fishing/fight_profiles/sea_trout.tres`：海鳟水面动作现在先下潜 0.35 m，再跃到水面以上 1.2 m，随后在水面上方侧翻约 82°洗鳃，最后以 0.75 秒快速提升；水面高度仍由 WaveSampler 采样。针鱼没有启用此动作。
- `resources/fishing/rod_mounts/{starter_cargo_boat,nordic28}.tres` 与 `scripts/fishing_rod_mount_profile.gd`：把 Fight Camera 注视点移回挂点和船尾鱼体之间，并让收线时再向鱼/水花方向移动，避免原先注视点偏到船尾过远处。
- 覆盖了卷轴水平轴、海鳟起跳的水下起点/最高点/回水、洗鳃阶段和后续提升阶段的 Headless 断言。Headless 不替代 Forward+ 视觉检查。

## 2026-10-30 鱼竿、卷线器与鱼线可见性修正

- 两种船的竿架挂点均上移 0.20 m：starter cargo boat Y=0.92 m，Nordic 28 Y=0.54 m，用于避开船尾栏杆；其他船体坐标不变。
- 卷线器视觉符号改为 -1。调用方正值仍表示收线，但轮盘现在按正确绕线方向转动；竖直轮盘面和水平轮轴不变。
- 修正入水点从船体根节点定位的错误：鱼线现从实际弯曲竿尖开始向船尾延伸，避免从竿尖折回甲板；水下线端沿收线过程跟随临时鱼体，最终连接到鱼头附近。
- 鱼、跃水位置和水花现在以船尾竿架为位置基准。旧 Nordic 28 鱼体终点在挂点前方；新位置把鱼放到船尾外侧，让左右挣扎、跃水和洗鳃有空间显示。
- 最初把线半径从 0.0038 m 调到 0.006 m；随后发现线圆柱网格与实例变换重复缩放半径，本次改用单位半径圆柱，实际半径设为 0.008 m，保留浅蓝无光照材质。
- 渐进收线中鱼体高度根据 WaveSampler 从水面下 0.10 m 过渡到水面上 0.06 m；两个偏移为 FishingRodSystem 导出参数。这样鱼到达船尾时不会始终被水面遮挡。
- 新增 [ANIMATION_LOGIC.md](ANIMATION_LOGIC.md)，列出演出流程、可调 Profile、固定动画公式/常数及 F3 人工观察时间点。

## 2026-10-30 鱼线与渔获落点调整

- `scripts/fishing_rod_rig.gd`：修正鱼线半径在圆柱网格和 MultiMesh 变换中重复缩放的问题，实际半径 0.008 m，单位圆柱只缩放一次。
- `scripts/fishing_rod_mount_profile.gd` 与两船 Mount Resource：增加船体局部坐标中的渔获落点和越栏杆短弧高度。
- `scripts/fishing_rod_system.gd`：鱼在水面挣扎后沿短弧进入船内甲板落点，并在甲板上完成渔获展示；移除挂点上方固定悬空展示。P2 结算仍只发生一次，HUD 仍显示捕获结果。

## 演出路径

临时鱼在 Hook Strike 和 Fish Struggle 阶段隐藏；渐进收线阶段靠近船尾并逐步露出动态水面；Surface & Landing 阶段先在 `WaveSampler` 采样的动态水面附近挣扎，再用较短的缓动完成提升；最后显示鱼种、P2 固定的天然体长和重量。临时模型不进入 Authority 或学校人口。

**P2 的中鱼概率、钓饵匹配、学校筛选、统计拟饵距离和鱼群数量均未修改。**

## 未完成及限制

- 当前没有可复用的相机遮挡碰撞接口；相机位置按船体挂点配置，没有增加第二套碰撞系统。starter cargo boat 和 Nordic 28 的最终遮挡、构图及鱼体/水花穿模仍需在 Forward+ 画面中人工检查。
- 本轮启动了 Godot 4.7.2 Forward+ / Apple Metal 项目进程，资源及 Öresund 场景初始化日志正常；但屏幕自动化当前捕获的是已打开的 Godot 编辑器窗口，未观察到游戏运行窗口。因此搏鱼动作和 Fight Camera 的画面验收标记为 **NOT RUN**，不能据代码/Headless 测试宣称视觉验收通过。
- 新启动的 Godot 运行进程仍保持运行，未自动终止。
