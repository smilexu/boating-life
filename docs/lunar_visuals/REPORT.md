# 北欧海景 2.0：月夜、星空与太阳视觉报告

测试项目：Godot 4.7.2 stable，Forward+ / Metal，Apple M2 Pro，1920×1080，High。渲染截图和性能采样均来自本机图形运行；Headless 只用于脚本与场景加载检查。

## 实现摘要

- 太阳圆盘沿用现有 Sky Shader 方向计算。视觉角半径从基准约 `0.42°` 调整为 `0.63°`，即直径增加 50%；核心辐射从 `3.4` 调为 `4.42`（+30%）。未改 DirectionalLight 能量、全局曝光或太阳轨迹。光晕继续使用原有衰减，未叠加第二个太阳。
- 新增低精度月球轨道近似。月球轨道相位在世界日历日期的 Stockholm 本地正午取样；日轮时刻只推进当地天空中的时角。因此同一现实日期的多个加速日轮保持相同月相，同时月亮在每个日轮内连续移动。该游戏化规则不会因日轮午夜而推进世界日历。
- 月相由太阳与月球黄经差计算照亮比例，Sky Shader 根据月面法线与太阳方向的点积形成明暗分界，并添加低对比度月海纹理；不是用固定方向遮罩裁切。近似轨道包含主要周期修正项，适合游戏画面，不是观测级星历。
- 星空用一张 2048×1024 R8 equirectangular 星点纹理（560 个星点，24 个较亮星点），在 Sky Shader 中按视线方向采样。亮度随太阳高度、云量和月相连续衰减；纹理不表示真实星座。
- 月光使用现有标准 Forward+ DirectionalLight3D/PBR 光照，最大能量 `0.065`，不投射阴影；强度受月相、月高、天气和昼夜权重调节。海面未新增网格或专用渲染 Pass，月光反射来自水材质现有 PBR 镜面项、Gerstner/细节法线和该方向光。实测满月例图的月光权重为 `0.0461`。
- Sunshine Clouds 2 的源码显示，其环境云光会乘以被判断为“太阳在地平线上方”的已跟踪方向光总能量。太阳落下后该权重趋近零，云因此变成近黑色。本项目没有改插件核心；DayNightVisualController 将现有插件公开的 tracked directional light 输入用于低强度 `NightCloudFill`，并在太阳高度低于约 12° 时渐进启用。该灯不投影、不照亮普通场景几何（`light_cull_mask = 0`），同时用天气缩放压低少云/阴天补光。测试显示夜云为可辨认蓝灰色，日落云仍有暗部层次。
- F3 时间面板增加天体只读状态与管理员测试操作；跳时、日期设置和恢复日历仍通过现有时间控制接口，未让 UI 直接改 WorldTimeManager 内部字段。

## 本阶段涉及文件

- 场景与天气接线：`scenes/main.tscn`、`scripts/weather_controller.gd`、`resources/sea_sky.tres`。
- 天文与视觉：`scripts/moon_position.gd`、`scripts/day_night_visual_controller.gd`、`resources/day_night_visual_profile.gd`、`resources/day_night_visual_profile.tres`、`shaders/sea_sky.gdshader`。
- 调试与验证：`scripts/boat_hud.gd`、`tests/test_moon_position.gd`、`tests/test_day_night_cycle.gd`、`tools/capture_lunar_visuals.gd`、`tools/benchmark_lunar_visuals.gd`、`tools/generate_starfield_texture.py`。
- 美术及记录：`assets/sky/stars_equirectangular.png`、本目录 A–J 截图、`capture_report.json`、`performance_after.json`、`performance_run_1.json` 和本报告。

世界时间状态、服务器接口和基础 F3 时间控制属于此前阶段的工作区内容；本阶段只消费其权威状态接口。工作区同时保留这些阶段的未提交文件，没有清理或重置它们。

## 关键参数

| 项目 | 当前值 | 说明 |
|---|---:|---|
| 太阳视觉角半径 | `0.63°` | 基准 `0.42° × 1.5`；半径、直径同比例增加 |
| 太阳核心辐射 | `4.42` | 基准 `3.4 × 1.3`；只改变天空圆盘 |
| 太阳光晕倍率 | `1.0` | 保留原有设置 |
| 月亮角半径 | `0.56°` | 软边 `0.045°` |
| 月亮核心辐射 | `1.8` | 冷银色，画面中可辨认但不做巨型月亮 |
| 月光最大能量 | `0.065` | 无阴影；实际强度还受相位、月高、天气控制 |
| 星星最大亮度 | `0.8` | 由太阳高度、云量、月相连续调制 |
| 夜间云补光上限 | `0.45` | 无阴影且场景灯光剔除掩码为 0；按云量缩放 |

## 截图

所有截图为 1920×1080、High，波浪时间冻结。A 是此前太阳视觉任务的历史基准截图，B–J 是本轮拍摄；由于 A 来自旧测试工具，无法保证它与本轮摄像机完全同位，适合作为观感参考，不应当作逐像素 A/B 测量。

| 编号 | 画面 | 文件 |
|---|---|---|
| A | 修改前晴天太阳历史基准 | [A_sun_before.png](A_sun_before.png) |
| B | 修改后太阳圆盘 | [B_sun_after.png](B_sun_after.png) |
| C | 日落太阳与海面 | [C_sunset_sun_and_sea.png](C_sunset_sun_and_sea.png) |
| D | 晴朗满月、星空及银色反光 | [D_full_moon_stars_reflection.png](D_full_moon_stars_reflection.png) |
| E | 上弦月 | [E_quarter_moon.png](E_quarter_moon.png) |
| F | 新月夜与星空 | [F_new_moon_stars.png](F_new_moon_stars.png) |
| G | 少云月夜 | [G_partly_cloudy_moon.png](G_partly_cloudy_moon.png) |
| H | 阴天深夜 | [H_overcast_deep_night.png](H_overcast_deep_night.png) |
| I | 日落时云层 | [I_sunset_clouds.png](I_sunset_clouds.png) |
| J | 月光下船只第三人称 | [J_moonlit_boat_third_person.png](J_moonlit_boat_third_person.png) |

机器可读的时间、天气、太阳/月亮方向和视觉参数记录见 [capture_report.json](capture_report.json)。

## 视觉回归观察

- B 中太阳轮廓仍然清晰，核心更亮；C 中日落颜色与海面暖色反光保持连续。没有改变太阳直射能量或曝光。
- D/E/F 展示满月、半月和新月三种阶段；新月夜无月盘、无明显月光，星点相对突出。D 的反光与月亮方向一致，表现为被波面打碎的银色高光，不是新增的连续白色光柱。
- G 为少云天气，云层没有在月盘前形成实际遮挡，因此这张图只验证少云下的亮度调节，不能视作云体遮挡验收。当前天空/体积云是两个渲染系统，云覆盖月盘时的严格前后合成仍需实际重叠镜头继续检查。
- H 的云层是低对比度冷蓝灰，未出现此前那种边界硬、近纯黑的团块。I 的日落云也保留蓝灰暗部与受光层次；部分云体仍偏暗，这是 SunshineClouds 2 体积光照近似的剩余限制。
- J 中船只仍可辨认，但测试镜头偏宽，船较小。满月反光路径可见，夜景仍是深蓝而非蓝色白天。
- 正午蓝海基准、海洋 Shader、水深着色、海面波浪及浮力没有改动。此任务未运行 7 月/12 月全套所有时刻的人工视觉矩阵；上述截图覆盖了晴天、日落、满月、半月、新月、少云和阴天夜晚。

## 性能记录

条件：Godot 4.7.2，Apple M2 Pro，Forward+ / Metal，1920×1080 High，VSync 关闭，帧率上限关闭，每个状态 240 帧。GPU 时间没有通过当前 Godot 运行时 Performance monitors 暴露。新增灯光没有投影阴影；云补光灯不照亮场景几何；Draw Calls 仍为 146–147。

| 状态 | 旧昼夜基线 FPS / 帧时 | 本轮 FPS / 帧时 | 本轮 p95 帧时 |
|---|---:|---:|---:|
| 夏季正午 | 93.03 / 10.75 ms | 61.24 / 16.33 ms | 24.31 ms |
| 夏季日落 | 96.88 / 10.32 ms | 60.06 / 16.65 ms | 22.52 ms |
| 冬季正午 | 99.14 / 10.09 ms | 61.61 / 16.23 ms | 23.15 ms |
| 冬季深夜 | 86.45 / 11.57 ms | 59.99 / 16.67 ms | 23.24 ms |
| 满月夜（本轮新增） | 无旧基线 | 91.87 / 10.89 ms | 12.20 ms |

这些数据波动较大，部分本轮场景接近 60 FPS，而同样关闭 VSync 的旧采样在 86–99 FPS；第二次本轮采样的满月场景为 91.87 FPS。因为结果没有稳定复现出同一性能区间，不能据此声称性能持平或回退。本轮没有新增海面 Draw Call，也没有 GPU 时间数据。详细采样见 [性能结果](performance_after.json) 和 [修改前结果](../day_night_continuity/performance_before.json)。

## 验证、运行方式与限制

- 运行：`godot --path /Users/smixu1/dev/boat-life-simulator`
- 自动化：`godot --headless --path . --script res://tests/test_moon_position.gd`（12 项通过）；`godot --headless --path . --script res://tests/test_day_night_cycle.gd`（136 项通过）。
- Headless 编辑器扫描与主场景启动检查完成。无渲染设备是 Headless 的预期限制；图形运行才验证画面。退出时 SunshineClouds 插件仍报告 RenderingDevice RID 泄漏警告，插件源码未改。
- 最终复查：`git diff --check` 通过。Headless 编辑器退出报告 1 个 ObjectDB 实例；图形运行退出时 SunshineClouds 还会报告 RenderingDevice 的 Pipeline/Compute/Shader/Texture RID 清理警告。插件源码未改；未观察到脚本或场景加载错误。
- 月球轨道和月相为游戏级简化算法；地理位置采用现有 Malmö–Copenhagen GeoReference。星点为艺术化分布，不是星图。云遮挡月盘的正确合成尚未在云体正好覆盖月亮的镜头验证。
- 只有 Apple M2 Pro 实机验证；Windows 与 Linux 没有测试设备，本报告不宣称跨平台实测通过。
