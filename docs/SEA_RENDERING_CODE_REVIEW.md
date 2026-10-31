# 正式场景海面渲染专项代码审查

日期：2026-10-31  
范围：静态代码审查；未修改代码或资源，未运行项目。

## 结论摘要

已确认正式场景与 `tests/water_minimal/water_minimal.tscn` 使用相同的 Ocean 插件脚本、海面 Shader、材质、波浪设置、Ocean 初始 LOD 参数及 `WaveSampler` 强度。最小场景没有正式游戏的天气控制器、测深纹理输入、QualityManager、鱼群 Shader 参数写入和 Sunshine Clouds 合成器。

按目前代码证据，优先怀疑：

1. **Sunshine Clouds 2 Compositor 的跨平台 GPU Compute 合成路径**：正式主场景独有，按屏幕分辨率分派 Compute 并把结果绘制回当前颜色缓冲。它最符合“同一水面资源、仅正式场景出现规则屏幕格纹”的场景差异，但尚无图像或运行时 A/B 证据证明它就是根因。
2. **正式场景加载的 RG8 测深纹理参与海水 Shader**：该输入会按海面世界坐标采样，且深度着色默认开启；它具有固定空间纹理格点，最符合随世界位置固定的规则纹理。最小场景没有 BathymetryManager，因此没有同一份运行时纹理输入。
3. **Windows 实际质量档改变 Ocean 网格分辨率/LOD**：主场景有 QualityManager，最小场景固定 12/4。若格纹沿网格边缘或随质量档改变而变化，优先级会上升；当前静态代码不能确认 Windows 实际选择的档位。

船舶浮力和波浪采样本身不是已确认的海面渲染写入来源。极端海况只在用户触发测试时才改动共享水面参数，且代码没有额外更改 Ocean 的 LOD 或 Mesh。

## 实际实现与数据流

- 网格来自仓库插件 `addons/boujie_water_shader/types/ocean.gd` 的 `Ocean.build_meshes()`；正式场景和最小场景均使用 `outermost_resolution=12`、`levels_of_detail=4`、`unit_size=1`、`far_edge=60000`。插件依相邻环的分辨率、单元尺寸生成近场网格及远场平面，见 [ocean.gd:41-47](../addons/boujie_water_shader/types/ocean.gd#L41)、[ocean.gd:114-137](../addons/boujie_water_shader/types/ocean.gd#L114)。
- 实际着色器是项目自己的 `shaders/sea_water.gdshader`，由 `materials/sea_water_material.tres` 引用。波形类型 `GerstnerWave` 来自 Boujie 插件；运行时波浪配置是项目自己的 `SeaWaveSettings`，资源为 `resources/sea_waves.tres`。
- `WaveSampler` 是 CPU 与 GPU 之间的同步点：波浪设置与强度由它写入同一 ShaderMaterial 的波浪 Uniform；它在 `_process` 每帧推进 `WaveTime`，见 [wave_sampler.gd:88-98](../scripts/wave_sampler.gd#L88)、[wave_sampler.gd:572-607](../scripts/wave_sampler.gd#L572)。Shader 随后在顶点阶段按世界 XZ 计算并平均叠加 Gerstner 位移，见 [sea_water.gdshader:363-374](../shaders/sea_water.gdshader#L363)、[sea_water.gdshader:430-456](../shaders/sea_water.gdshader#L430)。
- 正式主场景的 Ocean/WaveSampler 配置在 [main.tscn:93-113](../scenes/main.tscn#L93)；最小场景对应配置在 [water_minimal.tscn:33-48](../tests/water_minimal/water_minimal.tscn#L33)。两者参数一致，且均引用相同 `.tres` 资源。

## 模块审查

### A. 船舶浮力

`boat_buoyancy.gd` 每帧把四个船体采样点转换到世界坐标，再调用 `WaveSampler.sample_surface()` 读取高度；随后只改船只 `VisualRoot` 的升沉、俯仰和横滚。[boat_buoyancy.gd:42-88](../scripts/boat_buoyancy.gd#L42)

`sample_surface()` 是 CPU 端 Gerstner 公式，不进行 GPU 读回；它读取 WaveSampler 的有效波浪配置、强度、时间和可选浅水缩放，不修改这些来源，也不写海面材质。[wave_sampler.gd:478-548](../scripts/wave_sampler.gd#L478)

**判断：低嫌疑。** 浮力采样会改变船的位置与相机跟随目标，因而能间接改变观察视角和海面视锥；但没有路径能从浮力结果写入 Ocean Mesh、海面纹理或波浪 Uniform。它不能单独解释固定世界坐标上的方格海面。

### B. 风力与天气

`WindField` 提供由平均风和确定性阵风构成的风速/风向查询；`WeatherStateController` 将天气风状态应用到 WindField。[wind_field.gd:45-69](../scripts/wind_field.gd#L45)、[weather_state_controller.gd:106-122](../scripts/weather_state_controller.gd#L106)

代码搜索未发现 WindField 或 WeatherStateController 将风速、风向换算成 `SeaWaveSettings` 或写入波浪方向/频率/速度。风影响船帆等物理/天气表现，不构成海面 Gerstner Uniform 的第二写入者。海况 `WeatherController` 是另一条链：天气状态过渡时逐帧写水色、粗糙度等材质参数，并将预设 `wave_strength` 写回 WaveSampler。[weather_controller.gd:149-167](../scripts/weather_controller.gd#L149)、[weather_controller.gd:261-279](../scripts/weather_controller.gd#L261)

WaveSampler 的 `wave_strength` 属性 setter 会触发 `_apply_wave_parameters()`，所以更改强度时 CPU 采样和 GPU Uniform 会通过同一个 sampler 同步。这里没有独立的风浪生成器，也没有确认的重复风浪写入。

### C. 5/10/20/30m 极端海况

`ExtremeSeaStatePresets` 按预置波长计算频率和深水色散速度，并分配各波陡度/振幅；波长档位、陡度计算见 [extreme_sea_state_presets.gd:8-17](../scripts/extreme_sea_state_presets.gd#L8)、[extreme_sea_state_presets.gd:41-78](../scripts/extreme_sea_state_presets.gd#L41)，周期/速度关系见 [extreme_sea_state_presets.gd:115-120](../scripts/extreme_sea_state_presets.gd#L115)。

它构造新的 `SeaWaveSettings` 和 `GerstnerWave` 副本；WaveSampler 在过渡时插值各波方向、频率、速度、相位和陡度，并每帧重写 Uniform。[wave_sampler.gd:103-128](../scripts/wave_sampler.gd#L103)、[wave_sampler.gd:626-668](../scripts/wave_sampler.gd#L626)。代码还通过相位锚点修正波参数过渡在锚点附近的相位连续性，[wave_sampler.gd:671-690](../scripts/wave_sampler.gd#L671)。

在 2.5 秒过渡窗口中，世界坐标乘以变化中的频率/方向可能使远处相位变化很快；但这是连续坐标函数，并未按 Ocean 子网格边界分支或修改网格。**默认主场景与最小场景都没有激活极端测试**；只有 BoatHUD/实验面板调用 `set_extreme_sea_test()` 才进入该路径。[boat_hud.gd:3397-3414](../scripts/boat_hud.gd#L3397)

**判断：常规运行低嫌疑；触发极端测试时可单独复核。** 如果方格只在过渡过程中出现，才应上调此项。

### D. 浅水波浪衰减与测深纹理

正式场景中的 BathymetryManager 把 RG8 深度/覆盖图创建为 ImageTexture，并写入海水材质的纹理、范围和尺寸 Uniform。[bathymetry_manager.gd:485-517](../scripts/bathymetry_manager.gd#L485)

海水 Shader 使用线性过滤、禁用重复采样，并通过 `(world_east, world_north)` 映射到纹理 UV；Shader 中的地形色/透明逻辑会按当前世界坐标采样该纹理。[sea_water.gdshader:117-120](../shaders/sea_water.gdshader#L117)、[sea_water.gdshader:272-285](../shaders/sea_water.gdshader#L272)、[sea_water.gdshader:778-797](../shaders/sea_water.gdshader#L778)。因此，纹理本身的像素分辨率、边界、过滤/压缩以及坐标映射都可能留下固定的空间格点；这是当前最值得直接对照的水面材质输入之一。

CPU 浅水路径用相同 RG8 Image、范围、`east=x`/`north=-z` 映射和双线性插值，注释明确说其目标是匹配 GPU 线性纹理采样。[bathymetry_manager.gd:123-170](../scripts/bathymetry_manager.gd#L123)。Shader 浅水振幅缩放也使用同一纹理和世界坐标，[sea_water.gdshader:288-340](../shaders/sea_water.gdshader#L288)；CPU 端只在 `shallow_wave_constraint_enabled` 且 debug build 时采样，[wave_sampler.gd:315-360](../scripts/wave_sampler.gd#L315)、[wave_sampler.gd:478-495](../scripts/wave_sampler.gd#L478)。属性默认关闭，因此目前不能把浅水振幅衰减认定为常规运行原因。

**判断：测深纹理参与 Shader 的深度着色是中高嫌疑；浅水振幅缩放默认关闭，只有显式启用时才是额外波形几何嫌疑。** 若格纹跟着地理/纹理坐标固定，测深映射比 CPU 浮力更符合机制。

### E. GPU Compute / RenderingDevice

在审查的海水/波浪路径中，未发现项目用 RenderingDevice Compute 计算海浪顶点或直接生成海面 Mesh。海面顶点位移由 `sea_water.gdshader` 的常规 Spatial Shader 完成；BathymetryManager 使用 CPU ImageTexture 供 Shader 读取。

但正式主场景在 `WorldEnvironment` 上附加 `resources/sunshine_clouds_preview.tres` 中的 Sunshine Clouds 2 `CompositorEffect`，最小场景没有该 effect。见 [main.tscn:5-11](../scenes/main.tscn#L5)、[main.tscn:76-80](../scenes/main.tscn#L76)；资源引用了 Sunshine Clouds 的 pre/main/post Compute Shader，[sunshine_clouds_preview.tres:1-13](../resources/sunshine_clouds_preview.tres#L1)。

该 CompositorEffect 在 `PRE_TRANSPARENT` 阶段取得当前渲染颜色/深度，建立与屏幕分辨率有关的纹理和缓冲，执行三个 Compute 阶段，然后绘制回颜色缓冲。[SunshineClouds.gd:182-187](../addons/SunshineClouds2/SunshineClouds.gd#L182)、[SunshineClouds.gd:446-522](../addons/SunshineClouds2/SunshineClouds.gd#L446)、[SunshineClouds.gd:792-815](../addons/SunshineClouds2/SunshineClouds.gd#L792)

**判断：它不是海浪计算器，但它会处理海面已经渲染的屏幕像素，且是最小场景缺少的正式场景专属 GPU 路径。** 如果格纹是屏幕对齐、尺寸固定、随窗口分辨率或云层开关而变化，它是第一项应做开关 A/B 的差异。代码中 Compute 分派按 8×8 工作组和 `resolution_scale` 计算；静态代码没有证据证明其缓冲同步/生命周期错误，也不能证明方格一定来自工作组边界。

## 最小场景对照

| 项目 | 最小场景 | 正式主场景 | 审查意义 |
|---|---|---|---|
| Ocean 脚本 / Shader / 材质 / 海浪资源 | 相同引用 | 相同引用 | 基础水体实现并非差异 |
| Ocean 初始化参数 | 12 分辨率、4 LOD、1m、60km | 同值初始化 | 默认几何配置相同 |
| WaveSampler strength | 1.05 | 1.05 初始化，随后天气可改 | 正式场景运行时海况可能不同 |
| WeatherController | 无 | 有；改外观参数和 strength | 过渡期间每帧材质参数写入 |
| WindField / WeatherStateController | 无 | 有；控制风和船帆/天气 | 静态代码未发现其改 Gerstner 波数据 |
| BathymetryManager | 无 | 有；设置深度纹理 Uniform | 正式场景多出世界坐标纹理采样输入 |
| QualityManager | 无 | 有；按质量档调整 Ocean LOD/分辨率、细节 Shader Uniform | Windows 若使用不同档位，网格采样不同 |
| Sunshine Clouds Compositor | 无 | 有；每帧 GPU Compute/合成 | 最显著的全屏渲染路径差异 |
| Fish reveal / 夜间视觉 | 无 | 有；运行时写额外水面 Shader Uniform | 属于像素着色调制，非波浪网格生成 |

鱼群 Shader 写入 `surface_fish_reveal_spheres/count`，[fish_school_renderer.gd:848-868](../scripts/fish_school_renderer.gd#L848)；昼夜系统写夜间权重、颜色和粗糙度，[day_night_visual_controller.gd:270-272](../scripts/day_night_visual_controller.gd#L270)。这两者是正式场景额外 Uniform 写入，但从变量定义用途看，不控制 Ocean Mesh 或 Gerstner 参数；除非格纹与鱼群局部区域/昼夜变化相关，优先级低于 Compositor 和测深纹理。

QualityManager 的配置档确实可以把 Ocean 改为 8/3、10/4 或 12/4，并改变 Shader 细节淡出值，[quality_manager.gd:38-60](../scripts/quality_manager.gd#L38)、[quality_manager.gd:723-756](../scripts/quality_manager.gd#L723)。最小场景没有质量系统，因而即使两个场景的场景文件初始值一致，实际运行值仍可能不同。

## 优先验证排序（推测，非定论）

1. **Sunshine Clouds Compositor 的 Compute/合成（强差异证据，中等原因证据）**。唯一明显的全屏 GPU compute 渲染链；Windows 与 macOS 后端差异可能暴露边界/同步/采样问题。屏幕固定方格尤其支持该方向。最小场景不附加 compositor，故无此路径。
2. **测深纹理采样/映射（强差异证据，中等原因证据）**。正式场景才加载真实 RG8 地图，Shader 在海面 fragment 中用世界位置读取；纹理像素格点可能投影成空间纹理格。最小场景没有真实纹理。若格纹锁定世界坐标，此项优先级可超过 compositor。
3. **Ocean 质量档/LOD（强差异证据，低至中原因证据）**。质量系统能改变块大小和顶点密度，Windows 实际值未知。若接缝沿网格/LOD 环边缘并随分辨率变化，证据增强；否则不是首选。
4. **WeatherController 的 ShaderMaterial 写入（已确认额外写入，弱原因证据）**。天气渐变会改水色、粗糙度和 strength，但值在屏幕/空间上整体统一，不自然地产生固定方格。除非具体 uniform 出现非法值/数组问题，优先级低。
5. **浅水振幅衰减及极端海况（条件性风险）**。两者都在世界坐标计算中，不按网格块分支；浅水默认关闭，极端测试默认不启动。若相关开关开启、或只在极端过渡出现格纹，再独立检查。
6. **浮力（低）**。CPU 读取，不写水面；只影响船和相机姿态。

## 建议的最小验证顺序

以下是后续运行时验证建议，本次没有执行：

1. 在正式场景保持相同天气、相机、分辨率、质量档和波浪状态，只临时关闭 Sunshine Clouds Compositor。记录格纹是否消失；再开回。不要同时改水面 Shader 或网格。
2. 若仍在，保持其它状态不变，对照海水 Shader 诊断模式 2（waves、无 bathymetry）与模式 3（waves、with bathymetry）；或者临时禁用深度纹理输入。若格纹消失，检查 RG8 纹理尺寸、导入/格式、bounds/UV 映射和 Windows 采样结果。
3. 固定 QualityManager 为与最小场景相同的 12/4，并确认 `detail_normal_strength_near`、`detail_wave_fade_end`、`albedo_detail_fade_end` 与材质原值一致；观察格纹是否贴合 LOD 块/环。
4. 最后才分别启用浅水振幅约束和极端海况做单变量观察；仅对出现问题的路径截图对比。浮力无需作为首个关闭项。

判别记录时区分**屏幕对齐**（优先 compositor/屏幕尺度采样）、**固定世界位置**（优先测深纹理/世界坐标纹理）、**随视距或块环边界移动**（优先 Ocean LOD/顶点离散）三类特征。任何一项在做实际 A/B 前都只是候选原因。

## 本次限制与工作区状态

仅对上述相关源文件做静态检索和阅读；没有运行场景、截图或检查 GPU 帧数据。工作区在本审查开始前已有大量 `.import` 元数据修改，且 `tests/water_minimal/water_minimal.tscn` 是未跟踪文件；本审查没有改写这些既有状态，只新增本报告。
