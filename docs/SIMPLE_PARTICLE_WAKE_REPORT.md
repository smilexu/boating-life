# 当前船舶尾流方案

项目现在只维护 GPUParticles3D + ParticleProcessMaterial + shaders/particle_wake_foam.gdshader 尾流方案。旧动态带状 Mesh、Water Trail Shader 和相应的独立旧测试入口已移除。

## 独立测试场景

使用 scenes/SimpleParticleWake.tscn。该场景复用正式船只、天气、天空、动态海面、WaveSampler 和船尾跟随摄像机，但不把尾流接入正式 scenes/main.tscn。

| 输入 | 功能 |
| --- | --- |
| F6 | 停船 |
| F7 | 2 m/s 低速 |
| F8 | 7 m/s 巡航 |
| F9 | 12 m/s 高速 |
| F10 / V | S 形转弯 |
| F11 / K | 仅切换关闭 / GPU 粒子尾流 |
| F12 / O | 船尾跟随 / 倾斜俯视镜头 |

粒子采用世界坐标，船转弯后旧粒子留在原处。发射强度基于实测水平速度平滑变化，船停后停止产生新粒子，既有粒子依生命周期消散。尾流绘制 Shader 复用 WaveSampler 参数和时间基准，在顶点阶段近似贴合 Gerstner 海面；不使用每粒子 CPU 高度查询或 GPU 数据回读。

## 验证与限制

- 图形运行中检查过 STOP、2、7、12 m/s、S 弯和停船消散状态；自动状态检查输出的粒子稳态估算约为 0、33、135、206、136、0（容量 240）。GPUParticles3D 不暴露精确活跃数，所以这是基于发射比例的估算。
- 同场景短时基准中，GPU 粒子开启约增加 1 个 Draw Call；本次 M2 Pro 对照没有发现稳定、显著的 FPS 回退。完整分辨率与性能数据见 [PERFORMANCE_REPORT.md](PERFORMANCE_REPORT.md)。
- 船体之外的局部波面以 GPU 位移近似，仍可能有轻微高度差；粒子停留于世界位置，不模拟水流速度场。该方案只是受控的风格化泡沫效果。
- 目前未集成正式主场景；通过 F6 运行主场景不会生成该尾流。

## 已移除的旧版专属文件

- scenes/WaterTrailTest.tscn
- scripts/water_trail_test_controller.gd 与 .uid
- scripts/wake_trail_manager.gd 与 .uid
- shaders/water_trail_stylized.gdshader 与 .uid
- docs/WATER_TRAIL_EVALUATION.md

保留的 GPU 粒子专属文件：scenes/SimpleParticleWake.tscn、scripts/simple_particle_wake_test_controller.gd、scripts/particle_wake_manager.gd、shaders/particle_wake_foam.gdshader。正式海面、WaveSampler、船只控制器和浮力资源均未作为尾流清理目标。

