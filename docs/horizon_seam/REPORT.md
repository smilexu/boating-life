# 海平线暗线与远景地形排查记录

日期：2026-10-16  
项目：Godot 4.7.2 stable、Forward+ / Metal、Apple M2 Pro、1920×1080、High、晴天固定镜头。

## 结论

目前没有足够证据把所有黑线归结为单一原因。用户复看确认，正常画面中的一部分暗线/虚影来自远处陆地轮廓；该地形是真实海岸表现，应保留。一般航行镜头中的剩余细线并不明显。本轮没有找到能可靠消除剩余细线且不损害海面/天空的改动，因此没有宣称彻底修复。

另发现天空 Shader 上、下半球在 `EYEDIR.y == 0` 使用不同地平线颜色的潜在跳变。现将下半球从上半球地平线色开始，在 `-EYEDIR.y = 0…0.035` 区间平滑过渡到地面雾色，避免代码在半球边界直接跳色。当前画面仍可看到细水平线，因此这项修改不能视为黑线修复；它只处理天空调色函数的边界连续性。

## 排查与证据

所有诊断截图均为 1920×1080。可对照以下记录：

| 检查 | 结果 | 结论 |
|---|---|---|
| 标准第三人称与宽视角基线 | 记录了固定镜头；用户指出日常画面里部分显眼暗影是远处陆地虚影。 | 真实海岸轮廓保留，不以隐藏地形解决。 |
| 分离海洋与地形显示 | 本批固定宽角下，斜暗带在 ocean-only 图里仍可见，terrain-only 图里没有同样形状；用户指出的陆地虚影是另一类现象。 | 这组诊断不能把斜暗带归到地形；也不能否定正常游玩中确有陆地虚影。 |
| 纯色水面诊断（Shader 模式 1） | 保留水面几何时，水平细线仍可见。 | 细线不主要由太阳高光、Fresnel、水深颜色或常规水面着色产生。 |
| 平色且保留现有 alpha 距离淡出的诊断（模式 12） | 细线仍可见。 | 仅凭水面明暗/镜面项无法解释；水面轮廓、天空/地形深度关系或其他合成因素仍未排除。 |
| 近层与远层分组隐藏、相机旋转 | 未找到一个能稳定对应细线的单独 LOD 环。 | 尚无证据证明是特定 LOD 接边。 |
| 深度绘制模式：`depth_draw_always`、`depth_draw_never`、`depth_prepass_alpha` | 对比图没有显示细线因其中一种模式而稳定消失。 | 不支持直接修改深度绘制模式作为修复。 |
| 距离淡出与海面远边 | 改动淡出距离或 `far_edge` 后未能稳定消除细线；扩大远边没有足够收益。 | 已撤回实验值，避免扩大海面和潜在填充成本。 |
| 雾 | 当前 `fog_depth_begin=150m`、`fog_depth_end=3200m`；还对关闭雾及 `end=12000m` 作了对照。 | 没有证明雾能修复细线；恢复原配置，不以加雾掩盖问题。 |
| 天空单独渲染 | 日间 `sky_horizon_color=(0.4,0.64,0.82)` 与 `ground_horizon_color=(0.62,0.75,0.83)` 不同；夜间二者也不同。 | 天空半球接缝原因明确，已作小范围平滑处理。 |
| 角度 alpha 淡出 | 测试了关闭、默认、宽和窄区间；线条仍在。 | 实验无效，Shader 参数和实验代码已移除。 |

恢复正式参数后，又用固定第三人称镜头观察正常波浪 22.6 秒，并保存 5、10、15、20 秒画面；这段观察不足以确认细线按固定周期出现，也不能证明修复。它可能随镜头、几何重叠或地形投影而变化，尚不能定因。

## 截图索引

下列图片是诊断记录，不应解读为每一张都是同一问题或同一相机状态。`before` 表示本轮测试前的基线；`after` 表示本轮诊断时的画面，不代表已修复。

### 基线与视角

- [晴天第三人称基线](diagnostics/01_clear_third_person_before.png)
- [晴天宽视角基线](diagnostics/07_clear_wide_before.png)
- [宽视角海洋与地形同时显示](diagnostics/47_wide_ocean_and_terrain_baseline.png)
- [恢复正式参数后的第三人称捕获](final/01_clear_third_person_after.png)
- [恢复正式参数后的宽视角捕获](final/03_clear_wide_after.png)
- [恢复正式参数后的日落与月夜捕获](final/04_sunset_after.png)、[月夜](final/05_moonlit_after.png)

### 隔离与纯色诊断

- [第三人称纯色水面](diagnostics/03_clear_third_person_flat_water.png)
- [平色且保留淡出的第三人称水面](diagnostics/alpha_mesh/third.png)
- [宽视角仅显示海洋对象](diagnostics/48_wide_ocean_only.png)
- [宽视角仅显示地形对象](diagnostics/49_wide_terrain_only.png)
- [水面 LOD/深度绘制模式对照](diagnostics/depth_modes/depth_draw_always_all.png)、[Never](diagnostics/depth_modes/depth_draw_never_all.png)、[Prepass Alpha](diagnostics/depth_modes/depth_prepass_alpha_all.png)

### 环境条件

- [当前雾配置的地形单独显示](diagnostics/27_wide_terrain_only_fog_current.png)
- [关闭海洋和地形的天空基线](diagnostics/22_sky_only_day_hemisphere_baseline.png)
- [天空上、下半球地平线颜色相同的诊断对照](diagnostics/23_sky_only_day_horizons_equal.png)
- [夜间当前画面（细线仍可见）](final/05_moonlit_after.png)

## 保留及恢复的参数

| 设置 | 恢复/保留值 | 说明 |
|---|---:|---|
| 海面 `distance_fade_min/max` | `3600 / 4000 m` | 恢复原值。试过 `12000/24000`、`42000/58000`、`48000/60000`、`52000/56000`、`72000/78000` 等组合；没有确认可消除细线。 |
| Ocean `far_edge` | `60000 m` | 恢复原值。试过 `80000 m`，未证实改善。 |
| Environment fog | `150 / 3200 m` | 保留原始起止距离；关闭和延长到 `12000 m` 都未证实解决问题。 |
| 天空下半球地平线过渡 | `smoothstep(0.0, 0.035, -altitude)` | 保留。它仅平滑天空上下半球颜色连接。 |
| 水面波浪、太阳反射、水深颜色 | 不变 | 保持项目已确认的海面美术参数。 |

`water_diagnostic_mode=12` 作为可选诊断分支保留：它输出平色并保留距离/近景 alpha 淡出，默认模式仍为 `0`。它不是运行时美术效果。角度淡出实验已移除。

## 运行与性能

正常运行：

```sh
godot --path /Users/smixu1/dev/boat-life-simulator
```

本轮使用固定镜头捕获脚本和 Godot 场景加载检查。诊断图保存成功。测试环境为 M2 Pro 的 Metal；没有进行可靠的改动前后性能基准。个别捕获报告记录的是单次 FPS 读数（约 22–53 FPS，受启动与截图时机影响），不作为性能结论。不能据此声称性能持平或达到特定目标。

图形捕获脚本退出时 Godot 打印过 RenderingDevice RID 泄漏警告；Headless Editor 退出时也打印过一个 ObjectDB 泄漏警告。Headless 主场景启动退出码为 0，图形捕获成功保存画面，但这两类退出警告尚未单独定位，不能据此判断是本次 Shader 改动引起。

## 下次继续排查

1. 用玩家正常第三人称镜头对比“有/无真实远岸地形”，只把可确认的陆地虚影归到地形。
2. 若剩余细线仍明显，再分别可视化 farplane 的 transition/mid/far 三层边缘和深度，不先改反射、雾或海水颜色。
3. 对比 Ocean 被完全隐藏与仅保留天空/地形的同镜头画面；如线仍出现，沿场景对象/天空合成方向排查。
4. 保持 `far_edge=60000m`、距离淡出 `3600/4000m`、雾 `150/3200m` 作为当前基线，除非新证据要求更改。
5. 不隐藏 Oresund 地形，不用全局关雾/反射/波浪来规避视觉问题。
