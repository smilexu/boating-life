# 正式 GPU 粒子尾流：运行验证

更新时间：2026-10-15。正式 Boat 已在 `MotionRoot/VisualRoot/WakeSystem` 使用统一 `WakeSystem.tscn`；独立测试场景也直接操作这一个节点，不再创建第二套发射器。旧动态 Mesh / Water Trail 专属实现已移除。

## 正式集成

- `WakeSystem` 的发射点按当前船模尺寸放在局部 `+Z 2.75 m`，因为船头沿局部 `-Z`。尾流平面朝上，关闭阴影，GPU 粒子使用世界坐标。
- 系统以 process priority 200 在 BoatController 移动后采样导航节点的水平位移，不依赖油门或 `speed_mps` 目标值。手动与自动驾驶都由相同实测速度驱动。
- 低于 WakeProfile 可见速度时平滑停发，粒子自然淡出。大于 30 m 的单帧位移会清空历史粒子并重置速度基线。场景重载会创建新的空系统。
- 发射点每帧调用一次 WaveSampler；各 GPU 粒子再由绘制 Shader 共享波浪参数和时间更新高度，没有逐粒子 CPU 查询或 GPU 回读。
- 泡沫差异通过盒状发射位置随机、三种 Shader 轮廓、随机粒子缩放、生命周期随机度、轻微色相 / 透明度偏差和缓慢随机密度目标实现。速度响应不会使用周期性正弦脉冲。

## 三个配置

| Profile | 容量上限 | 起效 / 全效速度 | 关键设定 |
| --- | ---: | ---: | --- |
| `SailboatWake.tres` | 240 | 0.45 / 12 m/s | 窄、柔和；当前船默认 |
| `FishingBoatWake.tres` | 260 | 0.40 / 10 m/s | 中等宽度、泡沫与寿命 |
| `SpeedboatWake.tres` | 300 | 0.55 / 22 m/s | 更宽、更密；`future_v_wave_strength` 仅为未启用的预留值 |

新船在 `VisualRoot` 挂载 WakeSystem，按船尾与局部轴向调整 `WakeEmitter`，再在 Inspector 选择 WakeProfile；脚本无需复制。

## 运行验证

图形运行：

- 在 M2 Pro / Metal / Forward+ 下运行 `scenes/SimpleParticleWake.tscn`，WakeSystem 和泡沫 Shader 均成功创建，没有尾流脚本、节点路径或 Shader 编译错误。
- 运行正式项目入口 `godot --path . --quit-after 300`，主场景图形启动并完成 300 帧；无脚本错误。
- 在船尾和倾斜俯视镜头检查巡航泡沫；泡沫在船尾附近开始，转弯时形成弯曲的世界空间轨迹。粒子边缘不再是数条连续细线，也没有矩形网格边界。
- 1920×1080 与 3440×1440 的图形基准记录见 [PERFORMANCE_REPORT.md](PERFORMANCE_REPORT.md)。

输入 / 控制自动检查使用 `godot --headless --path . res://scenes/SimpleParticleWake.tscn -- --wake-integration-check`：

| 阶段 | 观测速度 | 发射比例 / 估算粒子 | 结果 |
| --- | ---: | ---: | --- |
| 手动加速 | 9.79 m/s | 0.509 / 122 | W 输入推动 BoatController，尾流同步开始 |
| 手动左转 | 12.03 m/s | 0.831 / 200 | A 转向期间保持发射 |
| 手动右转 | 12.01 m/s | 0.780 / 187 | D 转向期间保持发射 |
| 自动巡航 | 6.97 m/s | 0.501 / 120 | BoatController 自动驾驶分支正常驱动尾流 |
| 制动 | 0.00 m/s | 0.001 / 0 | 发射比例平滑降到近零 |
| 停船消散 | 0.00 m/s | 0.000 / 0 | 无新发射，旧粒子到期 |
| 150 m 瞬移 | 0.00 m/s | 0.000 / 0 | 自动清理旧粒子，没有生成瞬移长线 |

粒子数是 `容量 × amount_ratio` 的稳态估算；Godot 没有对本实现公开精确的 GPU 活跃数。三种 Profile 资源都已加载并通过 WakeSystem 运行时切换。手动转弯路径与独立 S 形测试在俯视画面中形成连续弯曲尾迹。

另一次 `--wake-state-check` 覆盖 STOP、2、7、12 m/s、S_TURN 与 STOP_FADE；实测速度约为 0、1.99、6.97、12.01、6.97、0 m/s，对应发射比例约为 0、0.097、0.461、0.739、0.455、0。低速至高速变化连续，S 弯期间仍发射，停船后归零。

## 已知问题

- 当前尾流仍由若干随机尺寸的浅色泡沫斑组成，近距离仍可分辨粒子形状；这是风格化简化效果，不是连续白色泡沫毯。
- 波面位置通过粒子平面顶点 Shader 做一轮 Gerstner 逆位移，较大波浪和远离摄像机的顶点衰减处会有少量误差。
- GPU frame time 不可用；Godot 退出时仍显示 Sunshine Clouds 2 的 RenderingDevice RID 泄漏警告。运行期间本轮未见 Compositor / Metal 错误，无法从现有证据将退出警告归因到尾流。
- 实测主机为 Apple M2 Pro，不是目标 Apple M4；M4 需要复测。
