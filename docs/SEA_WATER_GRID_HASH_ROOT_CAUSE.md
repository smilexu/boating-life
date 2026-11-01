# Windows 海面矩形块状异常：根因与修复记录

日期：2026-11-01  
适用范围：Godot 4.7.2、Windows Vulkan Forward+、项目海面细节 Value Noise。  
修复状态：基于 `4af8573e2e3d8692d5595f7c888a6e3620996ea1` 的工作区清理版本；远端提交未改写。

## 结论

异常最早出现在海面片元 Shader 的 `micro_slope`，早于最终法线、Fresnel 和水面 BRDF。Legacy 细节噪声使用浮点 `water_hash` 为 Value Noise 的格点生成值。该哈希把格点坐标经过浮点乘加、点积和 `fract` 混合；浮点表达式对求值顺序敏感，可能使同一共享格点在相邻噪声单元中得到不同值。Value Noise 的 quintic 插值和解析梯度假设共享角点值相同，因此这个差异会破坏边界连续性，形成坡度跳变，再由细节法线呈现为海面的矩形块状明暗。

这是根据坡度截图、float32 复算和 Legacy/Fixed Vulkan 对照得到的高置信度根因。没有反汇编实际 GPU Shader 指令，因此不能断言 Vulkan 驱动具体采用了哪种重排或 FMA，也不能把问题归咎于 Windows、Vulkan 或 Godot 的 Bug。

## 修复

细节 Value Noise 改用整数格点哈希：将 `floor(p)` 转成 `ivec2`，使用 32 位 `uint` 乘法、异或和移位混合，再用哈希高 24 位转换为 `[0,1)` 浮点数。相同整数格点因此获得相同哈希，不依赖浮点乘加顺序或 `fract`。

修复位置见 [sea_water.gdshader](../shaders/sea_water.gdshader#L481) 的 `water_integer_lattice_hash` 和 [Value Noise 调用点](../shaders/sea_water.gdshader#L495)。原 `water_hash` 保留给雨滴效果；细节 Value Noise 直接使用整数格点哈希。

Value Noise 插值和解析梯度、FBM 的频率/权重、细节法线混合、Gerstner 位移、Ocean 网格和测深系统均未因该修复而改变。Windows A/B 验证完成后，正式 Shader 中的 Legacy/Fixed 开关、重复 Legacy 细节噪声函数、Simplex 候选、频率层试验、法线候选和额外诊断模式均已移除。原算法截图仍作为历史对照证据保留；需要回看原实现时可从 Git 历史恢复。

## Windows 对照证据

使用同一份 F9 状态、相同相机和波浪时间，在 RTX 4070 Ti SUPER、Godot 4.7.2 Vulkan Forward+、1920×1080 下运行。有效组为 154826（Legacy）和 154835（Fixed）；更早的 154626/154633 组因 Legacy 包装改变了求值结构，不作为结论依据。

| 变体 | 正常海面 | 原始 `micro_slope` |
|---|---|---|
| Legacy | [截图](../tests/water_minimal/captures/water_replay_20261031_154826_495304_Legacy_normal.png) | [截图](../tests/water_minimal/captures/water_replay_20261031_154826_495304_Legacy_S_raw_micro_slope.png) |
| Fixed | [截图](../tests/water_minimal/captures/water_replay_20261031_154835_468305_Fixed_normal.png) | [截图](../tests/water_minimal/captures/water_replay_20261031_154835_468305_Fixed_S_raw_micro_slope.png) |

相机位于 `(12237.952, 1.836, 10059.494)`，旋转 `(-3.836°, 87.972°, 0°)`，FOV `58°`，`WaveTime=9.628762`。两组捕获参数分别见 [Legacy JSON](../tests/water_minimal/captures/water_replay_20261031_154826_495304.json) 和 [Fixed JSON](../tests/water_minimal/captures/water_replay_20261031_154835_468305.json)。

此前确认的坡度图像素 `(1700,751) → (1701,751)`，Legacy 反解值从 `(-0.041057, 0.048601)` 跳到 `(-0.120909, 0.082694)`，跳变量长度约 `0.08682`。Fixed 图中该像素对的 8 位 PNG 反解值相同，附近 20×20 区域最大相邻坡度差约 `0.00877`。ROI 的相邻坡度差 `p99.99` 从 Legacy 的约 `0.08170` 降至 Fixed 的约 `0.00973`。这些值受 PNG 量化影响，是截图估计，不是 GPU 高精度读回。

Legacy/Fixed 的坡度分量标准差接近（Legacy 约 `(0.0419, 0.0478)`，Fixed 约 `(0.0429, 0.0460)`），且诊断 ROI 没有映射饱和像素。因此块状跳变的减弱不是单纯降低细节坡度强度。正常渲染中大块边界明显减弱，细小波纹仍保留，未观察到新的明显重复方格结构。

清理掉 A/B 开关和临时 Shader 分支后，再用同一 F9 状态在 Windows Godot 4.7.2 Vulkan Forward+、RTX 4070 Ti SUPER、1920×1080 下回放一次。当前整数哈希正常画面目视未见原先明显的规则方格；Shader/脚本解析错误检索无匹配项。回放图像保存在 [正常模式](../tests/water_minimal/captures/water_replay_20261101_160347_652494_normal.png)、[模式 2](../tests/water_minimal/captures/water_replay_20261101_160347_652494_mode2.png)、[模式 9](../tests/water_minimal/captures/water_replay_20261101_160347_652494_mode9.png)、[模式 10](../tests/water_minimal/captures/water_replay_20261101_160347_652494_mode10.png) 和 [模式 6](../tests/water_minimal/captures/water_replay_20261101_160347_652494_mode6.png)。

按同一整数混合公式进行 CPU 复算，共享格点 `(5271,9770)`、`(5272,9770)` 分别得到 `uint` `4078356539`、`903148787`；相邻单元对同一格点的访问都传入相同整数坐标。这不是 GPU buffer 读回。Legacy 浮点哈希的两种等价求值形式经 float32 CPU 模拟，曾分别产生 `(5271,9770)` 的 `0.33984375`/`0.8115234375` 和 `(5272,9770)` 的 `0.5498046875`/`0.0830078125`，显示了该混合对运算顺序的敏感性。

## 排查中已排除或尚未证明的内容

- S 诊断在进入最终光照前已有跳变；因此 BRDF、Fresnel、反射不是最早来源。它们会影响正常画面的可见度，但不是这次修复针对的根因。
- 固定相机下，关闭太阳阴影、改变 Gerstner 法线候选、细节法线权重和噪声尺度等测试没有消除根本坡度边界。
- 接入 BathymetryManager 是最小场景复现异常的条件，但这次坡度跳变来自细节噪声哈希路径；没有证据证明测深数据直接参与了 `micro_slope`。
- Windows 对照确认 Fixed 在该 Windows Vulkan 环境消除了被追踪的异常边界。macOS Metal 尚未复测；不能据此声称两平台已验证一致，也不能断言根因是平台专属行为。
- Godot 运行记录了 shader cache 写入错误，但 Fixed Shader 实际在 Vulkan Forward+ 上渲染并保存了坡度和正常画面截图；没有观察到 Shader 编译失败信息。该缓存错误仍应与编译结论区分。

## 复现入口

测试场景为 [water_minimal.tscn](../tests/water_minimal/water_minimal.tscn)，F9 状态为 [water_repro_20261031_143746_684620.json](../tests/water_minimal/captures/water_repro_20261031_143746_684620.json)。简化后的运行器可回放当前整数哈希实现；加 `--water-grid-confirmed` 会额外保存现有诊断模式 2、9、10、6 的截图。CPU 回归入口为 [test_integer_lattice_hash.py](../tests/water_minimal/test_integer_lattice_hash.py)。Legacy/Fixed 原始对照截图是历史证据，不再由当前 Shader 开关重跑。
