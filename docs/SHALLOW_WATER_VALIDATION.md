# 浅海透视验证

## 范围

这是独立验证版，不改变正式水深数据。测试场景实例化正式 `main.tscn`，使用同一个 `sea_water.gdshader`、水面网格、天气、昼夜、太阳/月亮、船只和 WaveSampler；只在运行时将 ShaderMaterial 复制一份，并用 RG8 受控水深纹理替代该测试副本上的 EMODnet 纹理。真实缓存 `assets/geodata/processed/bathymetry/depth_texture.rg8` 保持不变。正式水面材质默认开启浅海透视；可将 `shallow_transparency_enabled` 设为 `false` 立即恢复原有不透明表现。

局部纹理沿世界东向编码 2 m、5 m、9 m 和无效数据区域；纹理 R 通道仍按现有格式表示 `depth_m / 64`，G 通道表示覆盖有效度，Shader 继续复用 `sample_bathymetry()` 的边界、南北翻转、解码和有效覆盖逻辑。为避免这张小测试纹理的矩形范围形成水色块，测试材质单独关闭深度水色；正式材质原来的深度水色设置不变。

## 透视逻辑

- `shallow_transparency_enabled` 是总开关；正式材质默认开启，测试场景也显式开启。
- 只有有效水深数据、深度小于 `shallow_max_depth`，且屏幕深度中有位于水面下并接近该水深海床的实体时，才减小该片水面的 Alpha。开阔水面、陆地/缺失数据和海床以外的远处物体不会触发透视。
- 浅海权重为 `1 - smoothstep(shallow_fade_start, shallow_max_depth, depth)`；默认 4 m 开始渐隐、6 m 回到完全不透明。有效覆盖也使用既有的 smoothstep。
- Alpha 在 1.0 与 `shallow_min_alpha` 之间按权重混合，并乘进既有 Alpha 路径；不全局调低 Alpha、不改变水色，也不加额外渲染 Pass。
- 为只显露当地水柱内的实体，使用已有 `depth_texture` 和 `depth_from_water_to_object()` 读取不透明场景深度，再按观察角与海图深度估算可见底部范围。这只在功能启用且水深有效、浅于上限的片元运行。

## 参数

| Uniform | 默认值 | 用途 |
|---|---:|---|
| `shallow_transparency_enabled` | `true` | 关闭后回到原水面外观 |
| `shallow_max_depth` | `6.0 m` | 到此深度透视权重归零 |
| `shallow_fade_start` | `4.0 m` | 由较强透视转向不透明的起点 |
| `shallow_min_alpha` | `0.62` | 最大透视处水面保留的 Alpha 下限 |
| `shallow_transmission_strength` | `0.60` | 透视权重缩放 |
| `shallow_absorption_per_meter` | `0.06` | 按估算水柱视线路径衰减海床透射 |
| `shallow_surface_above_lat_m` | `0.5 m` | 与海床管理器一致的水面相对 LAT 基准偏移 |
| `shallow_bottom_depth_padding` | `1.5 m` | 容纳波高、LAT 基准与小幅海床起伏的深度容差 |

这组值是正式场景浅海透视的当前基线；经过主场景 A/B 检查后，较先前更强的 `0.30 / 0.90 / 0.0` 设置保留了更多水面颜色与反射。后续视觉问题和截图见 `docs/SHALLOW_SEABED_VISUAL_DIAGNOSTIC.md`。

## 运行和操作

```sh
godot --path /Users/smixu1/dev/boat-life-simulator res://scenes/ShallowWaterTest.tscn
```

- `1`：垂直俯视；`2`：倾斜视角。
- `P`：切换透视开关。
- `D`：切换 `depth_draw_always`、`depth_prepass_alpha`、`depth_draw_never`。
- `V`：显示透视权重/有效数据遮罩（红色为透视权重，绿色为有效深度覆盖）。
- `F5`：暂停于正午；`F6`：暂停于 2026-10-26 23:00 的满月测试时间。
- `Esc`：退出。

自动生成相同测试状态截图：

```sh
godot --path /Users/smixu1/dev/boat-life-simulator --script res://tools/capture_shallow_water_test.gd
```

截图保存在 `docs/shallow_water_validation/`。自动测试只在运行期间覆盖世界时间，关闭 WorldTimeManager 自动保存，不改动保存的真实日期。

## Godot 4.7.2 / Metal 运行观察

环境：Godot 4.7.2 Forward+、Metal 3.2、Apple M2 Pro、1920×1080。截图由实际图形运行的主视口生成，画面无 Shader 编译报错。

- 俯视与斜视：2 m 区域能看到沙底与三块岩石；5 m 区域可见较淡的海床；9 m 区域和无数据对照仍由水面遮挡。
- 透视遮罩显示了 4–6 m 的连续过渡；大于 6 m 的权重为零，无效覆盖区域也不触发透视。
- Alpha 关闭的基准画面没有显示测试海床，开关打开后浅海海床出现。
- `depth_draw_always` 下能显示海床，保留了项目现有设置。`depth_prepass_alpha` 对照会先写入水面深度，使海床被挡住；`depth_draw_never` 在这个单水面测试中也能显示海床，但没有采用它，以免改变插件多层/LOD 水面的遮挡行为。
- 日间和满月时间截图均正常加载并渲染；当前对照镜头没有对准强烈的太阳/月亮反射路径，不能据此评定完整反射品质。透明区域的水面镜面分量会随 Alpha 一起衰减，这是透明混合的预期结果。
- 自动截图进程退出时 Godot 输出 RenderingDevice RID 泄漏警告（Pipeline/Compute/Shader/Texture 等）；运行期间未见 Shader 错误。该警告出现在场景退出清理阶段，本轮没有定位其具体资源所有者。

截图：

| 画面 | 文件 |
|---|---|
| 透视关闭的斜视基准 | [01_oblique_opaque_baseline.png](shallow_water_validation/01_oblique_opaque_baseline.png) |
| 透视开启的斜视 | [02_oblique_shallow_always.png](shallow_water_validation/02_oblique_shallow_always.png) |
| 透视开启的俯视 | [03_top_down_shallow_always.png](shallow_water_validation/03_top_down_shallow_always.png) |
| 深度/透视遮罩 | [04_top_down_transmission_mask.png](shallow_water_validation/04_top_down_transmission_mask.png) |
| `depth_prepass_alpha` 对照 | [05_oblique_shallow_prepass_alpha.png](shallow_water_validation/05_oblique_shallow_prepass_alpha.png) |
| `depth_draw_never` 对照 | [06_oblique_shallow_depth_never.png](shallow_water_validation/06_oblique_shallow_depth_never.png) |
| 满月时间夜间对照 | [07_night_shallow_always.png](shallow_water_validation/07_night_shallow_always.png) |

## 已知限制与下一步

- 海床和岩石是简单测试网格，测试水深与海床高度按场景摆放；这验证的是可见性/混合，不证明实际全区域海床与 EMODnet 数据已几何对齐。
- 水面透视依赖不透明深度缓冲，只能显示正常写入深度的实体；透明水下物体、屏幕边缘、极斜视线、海床与水深图不一致处仍需后续专门处理。
- 这是 Alpha 透视，不是折射或真实水体吸收；没有新增采样 Pass。总开关关闭时不执行新增深度读取。
- 建议先审阅 2 m / 5 m 的视觉强度与 4–6 m 渐变，再决定屏幕空间折射和按路径长度吸收。下一阶段若开展，应继续沿用此局部深度门控，并避免直接改变正式水色、海面网格或波浪系统。
