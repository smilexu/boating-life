# 北欧夏日海景 1.0：晴天海水调色

本轮只调整现有海水的颜色参数。海水 Shader、Gerstner 波浪、法线强度、反射、光照方向、天空与云没有重写或重配。

## 颜色来源与覆盖关系

- `materials/sea_water_material.tres` 提供编辑器预览和启动前的材质默认颜色。
- 游戏运行后，`WeatherController` 会把天气预设中的 `water_color` / `water_fresnel` 写入共享海水材质。因此运行时晴天底色以 Clear 预设为准，`.tres` 中的底色并不会单独决定最终颜色。
- 水深有效时，`sea_water.gdshader` 先用 `smoothstep` 在 2、5、10、20 m 之间混合浅水、中水、蓝水和当前天气底色，再以 `depth_color_strength` 与 Fresnel 底色混合。缺失或越界数据仍保持原颜色回退。
- 环境光、方向光、天空反射、Fresnel、SSR、粗糙度、色调映射和雾化继续影响最终屏幕颜色。水深颜色只改 `surface_color`，不改透明度、波形或光照结构。
- 发现 `QualityManager` 的三个档位原先会把 `detail_normal_strength_near` 从材质的 0.8 覆盖成 2.5 / 2.2 / 1.5。为了保留此前确认的低斑驳设置，本轮将三个档位的值统一为 0.8；其他画质项未动。

## 调整参数

晴天颜色输入值（Shader `source_color`，下表为 Godot 的 Color 参数值）：

| 参数 | 调整前 | 晴天调整后 |
| --- | --- | --- |
| `albedo` | `(0.026, 0.47, 0.39)` | `(0.14, 0.43, 0.58)` |
| `albedo_fresnel` | `(0.17, 0.52, 0.49)` | `(0.20, 0.50, 0.61)` |
| `shallow_water_color` | `(0.22, 0.62, 0.48)` | `(0.33, 0.57, 0.57)` |
| `mid_water_color` | `(0.06, 0.42, 0.46)` | `(0.19, 0.46, 0.55)` |
| `blue_water_color` | `(0.04, 0.30, 0.44)` | `(0.14, 0.38, 0.54)` |

保留：`wave_normal_strength=0.45`、`detail_normal_strength_near=0.8`、`depth_color_strength=0.6`，水深阈值仍为 2 / 5 / 10 / 20 m。没有增加 Shader 采样、噪声、渲染 Pass 或海面网格。

天气颜色在现有 `WeatherController` 预设中集中管理。PartlyCloudy 和 Overcast 的基础色、Fresnel 色以及浅/中/深水色保留调整前值；Clear 使用新蓝色组。上述颜色仍走现有 5 秒平滑天气过渡。

## 截图对照

截图来自正式 `scenes/main.tscn`，1920×1080、High / 原生 3D 分辨率、相同船位和跟船镜头、同一晴天光照、冻结 Gerstner 相位。A–D 仅切换水色参数和真实水深颜色开关。

| 状态 | 截图 |
| --- | --- |
| A0. 调整前实际 High 运行状态（旧质量档覆盖了细节法线） | [A0_clear_previous_high_runtime.png](summer_sea_color/A0_clear_previous_high_runtime.png) |
| A. 调色前、深度颜色开启，法线强度固定为 0.8 以隔离颜色变量 | [A_clear_before_depth_on.png](summer_sea_color/A_clear_before_depth_on.png) |
| B. 调色后晴天、深度颜色开启 | [B_clear_after_depth_on.png](summer_sea_color/B_clear_after_depth_on.png) |
| C. 调色后、深度颜色关闭 | [C_clear_after_depth_off.png](summer_sea_color/C_clear_after_depth_off.png) |
| D. 调色后、深度颜色开启 | [D_clear_after_depth_on.png](summer_sea_color/D_clear_after_depth_on.png) |
| 多云回归 | [E_partly_cloudy.png](summer_sea_color/E_partly_cloudy.png) |
| 阴天回归 | [F_overcast.png](summer_sea_color/F_overcast.png) |
| 晴天侧后方反光检查 | [G_clear_after_side_reflection.png](summer_sea_color/G_clear_after_side_reflection.png) |

A0–D 的太阳、天空、曝光和天气没有为了截图临时调整。A0 保留修改前 High 档实际覆盖值 2.5；A 与 B–D 固定在项目先前记录的 0.8，以便区分水色变化与质量档覆盖修正。G 只移动了相机到晴天太阳方向一侧，用于检查现有海面反光；没有改变太阳或反射设置。C 与 D 的水深颜色开关状态明确分别为关、开。海图读数约为 2.2 m，调色后近岸仍呈浅青蓝，与远处蓝色水域保持连续过渡。

观察结果：深水由偏墨绿转为柔和中蓝，近船水面为蓝与青蓝混合，浅水保留温和青绿色。没有新增大块色斑或分层色带；海面波纹层次仍在。多云和阴天截图仍分别保持较柔和蓝绿色与冷灰蓝环境氛围。太阳反射没有发现因调色而恶化；原有反光尺度未在本轮处理。

## 性能测量

工具：`tools/capture_summer_sea_color.gd`。每种颜色 3 轮，每轮预热 45 帧、计时 180 帧；相同晴天、镜头、波浪相位、材质诊断模式、场景及 1920×1080 输出。QualityManager 临时使用 High（测试不写玩家设置），VSync 关闭、`Engine.max_fps=0`。测量结果来自本机，不代表目标 M4 设备。

| 状态 | 三轮 FPS | 三轮平均 FPS | 合并帧时间 |
| --- | --- | ---: | ---: |
| 调色前 | 59.95 / 60.13 / 60.10 | 60.06 | 16.65 ms |
| 调色后 | 59.98 / 60.01 / 59.98 | 59.99 | 16.67 ms |

环境：Godot 4.7.2 stable、Forward+ / Metal 3.2、Apple M2 Pro、1920×1080、3D scale 1.0、VSync 0、FPS 上限 0。约 0.07 FPS 的差异处于这组短测的帧间波动范围内；颜色参数没有增加渲染开销。

## 复现

```sh
godot --path . --script res://tools/capture_summer_sea_color.gd
```

运行时按 `1` / `2` / `3` 平滑切换 Clear / PartlyCloudy / Overcast，按 `B` 开关真实水深颜色。调色截图与测试数据保存在 `docs/summer_sea_color/`；截图脚本和 `--quit-after` 启动检查在强制关闭时均出现 Godot RenderingDevice RID 泄漏警告，具体资源来源未确认。所有截图均成功写出（save error 为 0），且没有 GDScript 或 Shader 编译错误。

## 已知问题

- 设备实测为 M2 Pro，并非 M4；尚未在 M4 或 3440×1440 外接屏测量。
- 水深纹理分辨率、有效覆盖与海岸线数据自身误差仍会影响近岸颜色形状；本轮没有修改原始水深数据。
- 侧后视图保留了当前天空/云和海面高光原貌。原有太阳反光的宽度与云层观感不在本轮范围内。
