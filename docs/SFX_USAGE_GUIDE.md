# 航海模拟器 SFX 使用说明

更新日期：2026-10-21  
适用场景：`scenes/main.tscn`

本文说明 `assets/sfx/` 中各前缀素材目前在游戏里的实际用途。这里描述的是当前代码行为；素材文件存在不代表已经接入运行时。

## 总览

| 前缀 | 当前状态 | 游戏用途 | 音频总线 | 主要管理器 |
|---|---|---|---|---|
| OM | 已接入 OM02 | 当前初始动力船的发动机 | `Engine` | `BoatAudioController` |
| MM | 未接入 | 现代发动机素材，尚未转换或用于游戏 | — | — |
| R | 已接入 R02、R03 | 雨声 | `Weather` | `EnvironmentAudioManager` |
| S | 已接入 S01、S02 | 船体附近的拍浪声 | `Ocean` | `BoatAudioController` |
| SW | 已接入 SW01、SW02、SW03 | 持续的海面环境浪声 | `Ocean` | `EnvironmentAudioManager` |
| T | 已接入 T01、T02、T03 | 对应闪电事件的雷声 | `Weather` | `EnvironmentAudioManager` |
| W | 已接入 W01、W02 | 风声 | `Weather` | `EnvironmentAudioManager` |

持续环境音会平滑调整音量；雷声是单次事件音。各类环境音使用独立总线，玩家可在 ESC 设置菜单中调整天气音效、海浪/船体音效和发动机音量。

## 各类素材

### OM：发动机

- **OM02** 是当前初始动力船使用的老式发动机声音，播放 `assets/sfx/processed/OM02_loop.ogg`。
- 船只的发动机音频配置保存在 `EngineAudioProfile` 中。当前 Powerboat 默认档案使用 OM02，并包含针对该素材的 `+8 dB` 播放补偿。
- 音量与音高根据船只提供的动力代理平滑变化；代理读取油门或自动巡航目标，不是实际发动机 RPM。当前船舶系统没有独立点火/RPM 模拟。
- 后续动力船可以绑定自己的发动机档案；没有指定档案的 Powerboat 使用默认档案。推进类型为 `NONE` 的船不会播放发动机声。

相关文件：[默认档案](../resources/audio/powerboat_default_engine.tres)、[音频档案定义](../scripts/engine_audio_profile.gd)、[船只声音控制](../scripts/boat_audio_controller.gd)。

### MM：现代发动机

- **MM01–MM03** 目前没有运行时引用，也没有进入现有 SFX 的 OGG 处理清单。
- 它们是保留的现代发动机素材，尚未接入怠速、巡航或高速船型。

### R：雨声

- **R02** 用于中等降雨，**R03** 用于较强降雨；两者循环播放并平滑交叉混合。
- 驱动数据来自正式天气的降水强度（mm/h），不是雨粒子数量或视觉调试覆盖。
- 雨量为 0 时雨声静音。当前总雨声增益随雨量从 0 平滑升高；R02 到 R03 的素材交叉范围约为 4–15 mm/h。

相关代码：[环境音管理器](../scripts/environment_audio_manager.gd)、[混音曲线](../scripts/audio_mix_profile.gd)。

### S：船体拍浪声

- **S01** 是较轻的船体拍水底层，**S02** 是较强的拍浪声。
- 驱动数据来自现有浮力组件报告的船体升沉、俯仰和横摇速度；动作越明显，拍浪层越突出。
- 这是近船体的声音细节，与 SW 系列的持续海面环境声分开混音。S02 有增益上限，不会随船体动作无限增大。
- 音效读取已有运动状态，不为雨滴或波浪增加额外碰撞/采样。

相关代码：[船只声音控制](../scripts/boat_audio_controller.gd)、[拍浪混音曲线](../scripts/audio_mix_profile.gd)。

### SW：海面环境浪声

- **SW01** 表现较平静的海面，**SW02** 表现中等海浪，**SW03** 表现较大的海浪。
- 驱动数据来自 `WaveSampler` 当前生效的海浪设置与强度，因此 F3 极端海况调节也会影响混音。
- SW01 保留较轻的环境底层；海况增强时再平滑混合 SW02 和 SW03。
- 这套声音跟随当前海浪配置，不从风速另行推算波高，也不改变海浪物理。

相关代码：[环境音管理器](../scripts/environment_audio_manager.gd)、[海况混音曲线](../scripts/audio_mix_profile.gd)。

### T：雷声

- **T01** 用于远雷，**T02** 用于中距离滚雷，**T03** 用于近雷炸雷。
- 只有 `LightningEventController` 发出实际闪电事件时才排入雷声播放队列；不会因为下大雨或刮大风而单独随机播放雷声。正式闪电和本地开发者闪电测试都可以触发对应雷声。
- 根据监听者与闪电位置的距离计算传播延迟：`距离（米）÷ 343` 秒。
- 素材选择规则：小于 1200 m 使用 T03；小于 3500 m 使用 T02；更远使用 T01。播放使用 3D 位置声像，并对远雷降低音量和高频。
- 近雷会短暂压低音乐；强度有限，音乐开关和玩家音量设置不会因此改变。

相关代码：[闪电事件接入与雷声播放](../scripts/environment_audio_manager.gd)、[距离及延迟映射](../scripts/audio_mix_profile.gd)。

### W：风声

- **W01** 用于较轻的风，**W02** 用于较强的风，循环音量平滑交叉。
- 先读取船附近的 WindField 空气速度，再减去船舶速度，按相对风速混音，因此船在无风时航行也会感受到迎面风声。
- 当前 W01/W02 的交叉范围约为 4–14 m/s，整体风声增益设有上限。

相关代码：[环境音管理器](../scripts/environment_audio_manager.gd)、[风声混音曲线](../scripts/audio_mix_profile.gd)。

## 资源与处理状态

- 已接入的循环声音优先使用 `assets/sfx/processed/*_loop.ogg`；雷声使用处理后的 OGG 单次播放。
- 原始 MP3 保留在 `assets/sfx/`，不会作为音效运行状态的唯一依据。
- MM01–MM03 当前未处理、未接入。
- 雷声素材不会循环；风、雨、海面、船体和发动机素材由运行时循环播放器播放。

## 代码入口

- [BoatAudioController](../scripts/boat_audio_controller.gd)：发动机与船体拍浪（OM、S）。
- [EnvironmentAudioManager](../scripts/environment_audio_manager.gd)：风、雨、海面环境声和雷声（W、R、SW、T）。
- [AudioMixProfile](../scripts/audio_mix_profile.gd)：风、雨、海况、船体拍浪及雷声的映射曲线。
- [AUDIO-SFX-1 处理与接入报告](AUDIO_SFX_1_REPORT.md)：音频转换、资源导入、设置和既有测试记录。
