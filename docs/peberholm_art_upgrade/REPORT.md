# Peberholm 人工岛第一阶段美术升级

## 实现

- 岛顶仍使用原有 448 个地形三角面和原有顶点高程（Y=+1.25 至 +3.0m）。只替换 Peberholm 区域的材质：世界坐标程序化噪声混合灰绿色草地、灰褐裸土和浅灰碎石。材质不透明、写入深度；其他地形块继续使用原材质。
- 只将原有海岸过渡网格中匹配 Peberholm 轮廓 75m 范围的 1,212 个三角面分出，给它们使用程序化碎石材质。分区两侧的源三角面总数仍为 95,472，顶点位置和高度不变；其他海岸保持原材质。未添加石块几何，因此没有用道具遮挡岸边接缝。
- 低矮植被从现有岛顶三角面按面积采样，所有实例都通过 OSM 岛屿多边形检查，并距岸线至少 8–17m。固定种子 `812407` 生成 12,000 个草丛、900 株野生花草和 320 丛矮灌木。实例使用 118 个 MultiMesh 分区批次，无单株节点、碰撞体或逐帧生成。
- 草丛、野花、灌木分别在约 520m、260m、950m 处开始距离渐隐并隐藏。所有植被关闭阴影；较远处仍由地表材质提供色块。
- F3 Peberholm 地形诊断开启时，植被会隐藏，方便查看绿顶和红色岸坡；关闭诊断后恢复。

没有改动岛屿高程、轮廓、岸坡与封闭岛体几何、海面、桥梁或航行系统。

## Forward+ 验证

在 Apple M2 Pro / Metal 3.2 / Godot Forward+ 的完整主场景中加载并捕获：

- [海面低机位，约 9m 高](boat_approach.png)
- [近岸斜俯视](coast_oblique.png)
- [植被分布俯视](overhead.png)
- [全岛俯视，关闭诊断相机雾效](whole_island.png)

岛顶、岸坡和 MultiMesh 植被均可见；没有观察到植物落在海面或岛外。原有岛顶三角面数、高程范围和岸坡分区计数保持不变。图片由测试脚本生成的固定相机拍摄，海面低机位相机高 9m；不是逐帧录像，也不代表不同天气时段的完整玩家体验。

性能用相同水面低机位、相同完整主场景、90 帧预热后采样 240 帧。基线关闭本次材质与植被，功能版本开启。一次配对结果：

| 项目 | 基线 | 美术开启 | 差值 |
|---|---:|---:|---:|
| 平均帧率 | 165.4 FPS | 161.2 FPS | −4.2 FPS |
| 平均帧时间 | 6.045 ms | 6.203 ms | +0.158 ms |
| P95 帧时间 | 6.629 ms | 6.742 ms | +0.113 ms |
| 平均 Draw Calls | 153 | 171 | +18 |
| 平均渲染 primitives | 768,757 | 780,709 | +11,952 |

这是单机固定镜头的短样本，帧率会受其他进程和渲染负载影响；可确认批处理后该镜头增加 18 个平均可见 Draw Calls、约 12k primitives，平均帧时间增加约 0.16ms。长距离航行、不同分辨率和 Windows 设备尚未测量。

脚本退出时 Godot 仍打印项目中已有的 ParticlesShaderRD / RenderingDevice RID 清理警告；主场景、材质编译和截图均完成。此警告来自完整测试场景退出清理，当前检查没有把它归因到 Peberholm 美术节点。

## 运行与复核

```sh
godot --path .
godot --path . --script tools/verify_peberholm_art.gd
godot --path . --script tools/verify_peberholm_art.gd -- --baseline
```

验证脚本需要图形渲染，不能以 `--headless` 运行。输出目录为 `.godot/peberholm_art_preview/`。

## 参考

- [Øresundsbron: Peberholm (English brochure)](https://data.oresundsbron.com/cms/download/Peberholm_UK.pdf)：描述自然演替后的开阔干草地、局部湿地和灌丛。
- [Øresundsbron: Peberholm (Danish brochure)](https://data.oresundsbron.com/cms/download/Peberholm_DK_0.pdf)：说明岛由海床开挖材料建成，外围为石砌护岸。
- [Øresundsbron 官方 Peberholm 介绍](https://www.oresundsbron.com/en/about-oresundsbron/about-us/facts-about-oresundsbron/peberholm)。

灰盒植被是风格近似，不对应岛上的真实植物物种，也不实现真实湿地水体或生态分布。
