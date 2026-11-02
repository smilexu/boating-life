# P6.2.1 抛竿蓄力与手感

## 修改内容

- `scripts/boat_fishing_casting_system.gd`：增加 CHARGING 状态、按住蓄力/松开校验抛投、距离映射、前甩、竿身恢复、鱼饵飞行与动态水面落水流程。蓄力期间不创建鱼饵、不显示鱼线，也不锁定玩家；有效释放后才锁定移动。
- `shaders/boat_fishing_rod_bend.gdshader`：沿竿身中心线做连续曲率弯曲，并同步旋转截面法线，让竿尖弯曲不只是整体摆杆。
- `scripts/boat_hud.gd`：增加随蓄力填充的紧凑指示条；点击打开活动菜单时取消蓄力。
- `project.godot`：将鼠标左键注册为 `boat_fishing_cast` InputMap 动作。
- `resources/translations/fish_species.csv`：更新抛竿提示，并增加蓄力中英文文案。
- `tests/test_p6_2_casting.gd`：扩展蓄力曲线、距离、输入、取消、鱼饵飞行/入水及自动驾驶回归验证。

## 参数与动作

- 满蓄力 `cast_charge_full_time = 2.5 s`；0.4 秒完成明显起手，1.5 秒进入后扬后段，2.5 秒达到并保持最大值。
- 最大后扬 `cast_max_back_angle_deg = 65°`；竿身满蓄力曲率参数为 `cast_full_bend_angle_deg = 30°`。
- 抛投前甩 `cast_release_duration = 0.55 s`，约 0.19 秒后释放鱼饵；竿尖阻尼恢复 `cast_recovery_duration = 0.65 s`。
- 蓄力使用 `pow(ratio, 0.78)` 映射到 3–25 m；超过满蓄力时间后保持满值。
- 鱼饵按距离使用 0.42–1.18 秒飞行，并以共享 WaveSampler 的当前动态水面采样决定落水和 WAITING 时机。飞行轨迹和落点存于世界坐标；船速只给鱼饵一个小幅初始漂移。

## 验证

- `godot --headless --editor --path . --import --quit`：完成导入；输出仓库已有的两组重复 translation UID 警告及一次 headless ObjectDB 清理告警。
- `godot --headless --path . --script tests/test_p6_2_casting.gd`：通过，覆盖 0.5/1.0/1.5/2.0/2.5 秒姿态递增、2.5 秒实际满蓄力与超时保持、短按距离、蓄力中转向、InputMap、无效方向、O/菜单取消、飞行与落水、收竿移动恢复及自动巡航保持。退出时 Godot Headless 报告一条 `RendererDummy MaterialStorage DummyShader` RID 清理告警；测试断言均通过。
- `git diff --check`：通过。
- Forward+ 实际视觉验收：`NOT RUN`；需人工确认 65° 后扬和 30°竿身曲率在游戏镜头中的实际强度，再微调视觉幅度。
