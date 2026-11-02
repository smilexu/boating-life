# P6.2.5 — 船钓卷线器与音效报告

## 实施内容

- `FishingRodRig.create_reel_assembly()` 现在是拖钓与手持船钓共用的程序化卷线器装配。固定线杯与绕线转子分开；摇柄、轮臂和辐条随转子运动。船钓卷线器安装在鱼竿的 `RodSwing` 局部节点下，因此扬竿、前甩和摆竿都会带动它。
- 船钓卷线器只根据每帧实际线长变化驱动：收线时按线速换算转速（5 rad/s per m/s，限幅 18 rad/s），并轻微轴向往复线杯；放线时转子不反向空转，出线由实际延长的鱼线和出线音表现。卷线器动画不回写鱼线长度。
- 船钓通过 `FishingRodSystem` 现有播放器、循环流、短淡入淡出、SFX 总线和环境音压低复用音效；没有新增播放器或音频管理器。循环请求只在实际线长有对应变化时开启，松开操作、停止变化或结束活动后撤销。

## 音效映射

| 音效 | 船钓触发点 |
|---|---|
| `fishing_line_out.wav` | 抛投中鱼线实际放出；WAITING 中按住 **F** 且实际线长增加 |
| `fishing_reel_in.wav` | WAITING 手动收线或 RETRIEVING 中实际线长缩短；停止变化后淡出 |
| `fishing_drag.wav` | 自动控制持有输入且实际线长增加；普通摆竿、手动放线不会触发 |
| `fishing_splash.wav` | 不在鱼饵落水时播放。船钓当前尚无真实鱼出水事件，待该事件接入后再触发；拖钓仍由真实/模拟鱼离开水面的既有事件触发 |
| `fishing_catch_success.wav` | 提供按渔获批次去重的 `report_catch_succeeded(batch_id)` 接口 |

当前 P6.2 船钓尚未连接真实中鱼/成功结算事件，因此没有自动触发船钓的泄力、鱼出水或成功提示。鱼饵入水保留视觉水花，但不再播放鱼扑腾音。P6.3 的真实流程应在对应鱼出水/成功事件处触发音效，并在自动收放线期间更新权威线长；本轮没有伪造中鱼或渔获。

## 用户画面反馈修正

- 原因是船钓刚开启时鱼竿视图模型要等到首个 `_process` 才按玩家位置定位，首帧及快速切换时卷线器仍留在船体原点。现于活动开启时立即执行鱼竿定位；卷线器使用手持鱼竿局部轴安装。定向测试确认转子投影位于第一人称视口内。
- 钓线材质现以较高透明绘制优先级绘制，禁用深度测试和深度写入，以免海面的 `depth_draw_always` 深度通道把线在水面处截断。线仍是细的单个活动网格。
- 鱼饵入水只保留视觉水花，已移除 `fishing_splash` 声音触发。该声音不再用于抛饵；船钓尚未接入真实鱼出水/渔获流程，因此目前也不会在船钓中播放鱼扑腾声。拖钓仍由真实/模拟鱼离开水面的既有事件触发。

## 验证

- `godot --headless --path . --script res://tests/test_p6_2_5_reel_audio.gd`：通过；覆盖装配结构、转速方向/限幅、放收线音效条件、自动线长方向、循环所有权清理和成功批次去重。
- `godot --headless --path . --script res://tests/test_p6_2_casting.gd`：通过；覆盖真实抛投/落水、F 放线、手动收线、自动回收及拖钓视角/鱼竿回归。测试退出时 Godot 输出一条 DummyShader RID teardown 提示。
- `godot --headless --path . --script res://tests/test_fishing_p3_1.gd`：通过；既有拖钓卷线器轴向和旋转方向回归通过。
- `godot --headless --path . --script res://tests/test_trolling_audio_integration.gd`：通过；五个 WAV 的导入、格式、长度、循环及环境音压低回归通过。
- `godot --headless --path . --editor --quit`：导入和脚本注册通过；编辑器仍报告既有文档翻译 UID 重复警告及一次退出期对象清理提示。
- `git diff --check`：通过。
- Forward+ 下卷线器构图与实际听感：**NOT RUN**。本轮自动检查验证的是事件请求和播放器复用，未完成可交互画面检查或人工试听。

## 涉及文件

- `scripts/fishing_rod_rig.gd`
- `scripts/fishing_rod_system.gd`
- `scripts/boat_fishing_casting_system.gd`
- `tests/test_fishing_p3_1.gd`
- `tests/test_p6_2_casting.gd`
- `tests/test_p6_2_5_reel_audio.gd`
