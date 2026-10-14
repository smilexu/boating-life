# 天气视觉系统

Sea Prototype 使用 Godot 原生 `ProceduralSkyMaterial` 绘制蓝天渐变，WorldEnvironment 的雾效处理地平线大气感。三种天气的云都由 Sunshine Clouds 2 的体积云 CompositorEffect 绘制；旧的自制二维云 Shader 和旧单层云参数已删除，没有并行回退实现。

## 天气与调参

- `resources/sea_sky.tres` 保存原生天空渐变、地面地平线颜色和太阳圆盘参数。
- `resources/cloud_weather_profiles.tres` 保存 Clear、PartlyCloudy、Overcast 的插件云覆盖度、密度、光照强度和环境云色。
- `resources/sunshine_clouds_preview.tres` 保存插件体积云噪声、云层高度和质量设置；主场景和比较场景共用该资源。
- `WeatherController` 对天气、太阳和云参数执行平滑过渡；按 1/2/3 切换 Clear、PartlyCloudy、Overcast。太阳高度和方位也能由调试面板调整。
- 云覆盖度是 Sunshine Clouds 2 的密度分布参数，不代表画面像素覆盖率。

插件版本、当前设置、运行验证和已知限制记录在 [Sunshine Clouds 2 评估](SUNSHINE_CLOUDS_EVALUATION.md)。
