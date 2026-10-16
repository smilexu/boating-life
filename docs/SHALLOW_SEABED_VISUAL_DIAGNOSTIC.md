# 浅海透射与海床视觉诊断

日期：2026-10-16  
场景：正式 `scenes/main.tscn`，1920×1080，Godot 4.7.2 / Forward+ / Metal 3.2 / Apple M2 Pro。

## 结论

浅灰色大区域主要由**浅海透射与海床共同作用**造成，而不是单独的海床网格或单独的水面透明开关：

- A（海床关、透射关）、B（海床开、透射关）、C（海床关、透射开）都保持蓝色海面。
- 只有 D（海床开、透射开）出现大面积浅灰色底部贡献及明显的近/远过渡。
- 旧设置 `shallow_min_alpha=0.30`、`shallow_transmission_strength=0.90` 在权重达到 1 时保留的表面 Alpha 是 `mix(1.0, 0.30, 0.90)=0.37`，即最多约 63% 的场景颜色来自海床。正式起点的海床是灰褐色、粗糙度 0.97，透过水面后容易读成一片灰色地板。
- 岩石使用低饱和中性灰色顶点色，因此近景也显得灰暗、缺少材质区分。它不是由水面 Alpha 单独造成，但透射会加强这种观感。

**没有发现海床穿过水面。** 船的启动位置查询到 EMODnet 水深 2.243803 m（LAT）。海面静水位为 `y=0.000 m`；海床生成公式为 `-(depth + 0.5m LAT 对齐偏移) + 视觉起伏`，实测该点海床 `y=-2.737 m`。WaveSampler 冻结采样高度为 `y=-0.042 m`，当前净空约 2.695 m。根据正式五组波的垂直位移公式和强度 1.05，保守最大向下位移约 0.260 m；该点估算最低净空仍约 2.477 m。计算未显示波浪最低处会碰到海床。

夜晚的浅色波状区域在 G（海床关、透射关）中已经存在，H（两者开启）只是有轻微亮度差异。因此它不是此次海床透射的主要产物；更可能来自既有水面波浪受光/反射。当前没有改动海面夜间光照。

## 修复

沿用现有 Boujie 派生海面 Shader、深度缓冲门控和数据，不改第三方插件原文件、海床高度、水深数据或波浪：

| 设置 | 原值 | 当前值 | 作用 |
|---|---:|---:|---|
| `shallow_min_alpha` | 0.30 | 0.62 | 提高透视时仍保留的水面基底 |
| `shallow_transmission_strength` | 0.90 | 0.60 | 降低海床颜色在混合中的占比 |
| `shallow_absorption_per_meter` | 0.0 | 0.06 m⁻¹ | 根据视角估算水面到海床的视线路径，水程越长越多保留水面 |
| `shallow_fade_start / max` | 4.0 / 6.0 m | 不变 | 4–6 m 继续平滑淡出 |
| `shallow_bottom_depth_padding` | 1.5 m | 不变 | 保持屏幕深度底部门控容差 |

透射按 `exp(-coefficient × estimated_view_path)` 衰减；垂直视线也计算水柱厚度，斜视线会进一步增加路径，因此能看到海床但优先保留水面颜色与反射。水柱使用 LAT 水深、`shallow_surface_above_lat_m` 与当前水面世界高度计算；海床管理器在启动时把 `water_surface_above_lat_m` 同步到这个 uniform。该估算不是完整的折射/Beer-Lambert 水体模拟。船位冻结波高 `-0.042 m`，水深 `2.2438 m`，垂直视线估算水柱约 `2.7858 m`，透射权重约 `0.508`、有效水面 Alpha 约 `0.807`；斜视线时水面 Alpha 更高。

海床着色只作轻微区分：沙色略暖、泥色略偏灰绿、岩色略偏冷蓝灰；海床粗糙度保持 0.97，仍以漫反射为主。岩石由五组低饱和灰褐色调组成，面片明度变化从约 0.78–1.14 扩为 0.72–1.20，材质粗糙度从 0.96 调至 0.90。保留低面数模型与无碰撞/批量渲染方式。

当前生产海水仍使用 `wave_normal_strength=0.45`、`detail_normal_strength_near=0.8`、`depth_color_strength=0.6`。关闭 `shallow_transparency_enabled` 可回退到原不透明海面；F6 仍可在运行时切换透射。

## A/B 截图

截图来自相同主场景、船位、固定相机、晴天和正午；波面时间冻结。`before` 是旧透射参数，`after` 是修复参数。两组均使用性能优先档（0.67 的 3D Resolution Scale），窗口/截图尺寸 1920×1080，估算的内部 3D 渲染尺寸约 1286×724；捕获脚本会在运行时明确设置两套参数，不修改保存的材质资源。

| 状态 | 修改前 | 修改后 |
|---|---|---|
| A：海床关 / 透射关 | [截图](shallow_seabed_visual_diagnostic/before/A_seabed_off_transparency_off.png) | [截图](shallow_seabed_visual_diagnostic/after/A_seabed_off_transparency_off.png) |
| B：海床开 / 透射关 | [截图](shallow_seabed_visual_diagnostic/before/B_seabed_on_transparency_off.png) | [截图](shallow_seabed_visual_diagnostic/after/B_seabed_on_transparency_off.png) |
| C：海床关 / 透射开 | [截图](shallow_seabed_visual_diagnostic/before/C_seabed_off_transparency_on.png) | [截图](shallow_seabed_visual_diagnostic/after/C_seabed_off_transparency_on.png) |
| D：海床开 / 透射开 | [截图](shallow_seabed_visual_diagnostic/before/D_seabed_on_transparency_on.png) | [截图](shallow_seabed_visual_diagnostic/after/D_seabed_on_transparency_on.png) |

修改后 D 的水面以蓝色表面为主，底部仍可辨认，灰色区域与近/远过渡明显减弱。对 D 图像下方中间 720×330 像素区域做 sRGB 均值比较，RGB 从约 `(0.579, 0.598, 0.596)` 变为 `(0.413, 0.540, 0.578)`；红通道下降、蓝色占比提高，符合减少中性海床混入的诊断。近景岩石/海床对照：

- 透射关：[修改前](shallow_seabed_visual_diagnostic/before/E_reef_closeup_transparency_off_before.png) · [修改后](shallow_seabed_visual_diagnostic/after/E_reef_closeup_transparency_off.png)
- 透射开：[修改前](shallow_seabed_visual_diagnostic/before/F_reef_closeup_transparency_on_before.png) · [修改后](shallow_seabed_visual_diagnostic/after/F_reef_closeup_transparency_on.png)

夜间对照（2026-12-15 23:00）：

- 海床关 / 透射关：[修改前](shallow_seabed_visual_diagnostic/before/G_winter_night_seabed_off_transparency_off.png) · [修改后](shallow_seabed_visual_diagnostic/after/G_winter_night_seabed_off_transparency_off.png)
- 海床开 / 透射开：[修改前](shallow_seabed_visual_diagnostic/before/H_winter_night_seabed_on_transparency_on.png) · [修改后](shallow_seabed_visual_diagnostic/after/H_winter_night_seabed_on_transparency_on.png)

## 性能与检查

在同一图形进程、相同主场景与相机中成对测量 240 帧，先预热 90 帧：

- 旧值：59.982 FPS，16.6716 ms/帧。
- 新值：59.993 FPS，16.6687 ms/帧。
- 差异约 -0.0030 ms/帧（约 0.02%），低于本次测量能稳定分辨的范围；结果接近 60 FPS，不能据此声称无 GPU 成本。

海床和透射完整开启的夜间读数为 59.937 FPS（16.6843 ms/帧）。实际场景画面 FPS HUD 与成对帧时间测量均保留；这不是 3440×1440 外接显示器性能测试。

图形捕获进程退出时仍打印 RenderingDevice RID 泄漏警告（Pipeline、Compute、UniformSet、StorageBuffer、UniformBuffer、Shader、Buffer、Sampler、Texture 等）。运行期间没有观察到水面 Shader 编译错误；退出清理警告与已有浅海验证记录一致，本轮未能定位具体插件/资源所有者，也未进行无关渲染架构重写。

## 已知问题

- 近距离低面数礁石仍是风格化灰褐色外观，明暗面可见但并非高精度岩石材质。
- 4–6 m 过渡通过水深权重平滑处理，但底部可见边缘仍会受 EMODnet 栅格分辨率、地形简化和视角影响。
- 夜间浅亮波纹已在关闭海床和透射时复现，归属于现有水面光照/反射候选；本轮不改夜间海面系统。
- 透射依赖 opaque depth buffer；透明水下物体、极端斜视角及海图与局部简化地形不吻合处仍有近似误差。

## 复现

```sh
godot --path /Users/smixu1/dev/boat-life-simulator --script res://tools/capture_shallow_seabed_ab.gd -- --after
```

脚本写入 `docs/shallow_seabed_visual_diagnostic/after/`，会临时冻结主场景时间、船只移动与水波，仅用于成图，不保存游戏状态。
