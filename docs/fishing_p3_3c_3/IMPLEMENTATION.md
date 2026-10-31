# Fishing P3.3c.3 — 实施记录

## 改动

- `shaders/fishing_catch_deform.gdshader`：悬挂鱼体现在把一整段身体曲率与独立的尾部高速波叠加。身体沿长度形成反向的 S 形双曲率，尾部相位独立抽打；头部前 16% 使用平滑约束，嘴部仍固定在线端。
- `scripts/fishing_rod_rig.gd`：分开传入身体和尾部相对体长振幅；默认海鳟约为 24% / 38%，针鱼约为 19% / 33%。形变只改 Shader 参数，不重建网格、不上传 CPU 顶点。整体悬挂摆动上限按原值的 1.5 倍提高并限制在 6°。
- `scripts/fishing_fight_profile.gd` 与 `resources/fishing/fight_profiles/{sea_trout,needlefish}.tres`：海鳟身体频率 4.0 Hz、尾部 6.2 Hz；针鱼 4.7 Hz、6.8 Hz。两种鱼都有 4 秒内的交替爆发脉冲，随后逐步降低强度。
- `scripts/fishing_rod_system.gd`：悬挂挣扎强度默认为 3.0×，范围 0.5–4.0；只改变表现，不改变 P2 时间或结算。实时调整会立即重采样当前演出姿态。
- `scripts/fishing_debug_panel.gd`、`resources/translations/fish_species.csv`：F3 模拟中鱼区域新增中英本地化的强度 SpinBox，播放期间可调。
- `tests/test_fishing_p3_3c_1.gd`、`tests/test_fishing_p3_2.gd`：增加形变幅度、C/S 曲率、鱼嘴固定、两鱼种网格密度、滑块实时值及翻译检查。

## 动作参数

默认 3.0× 时，Profile 振幅直接代表目标相对体长比例；爆发包络用确定性时间脉冲和演出 seed 控制，前约 4 秒包含 5 次强爆发及短间隔，之后逐渐衰减。身体曲率幅度限制为 25% 体长，尾部限制为 40%，不会随强度滑块超过该几何上限。

F3 → Fishing → 模拟中鱼区域的「悬挂挣扎强度」可运行时调整。选好鱼种和长度后启动模拟，跳到出水/展示阶段观察；暂停和重播行为保持原有实现。
