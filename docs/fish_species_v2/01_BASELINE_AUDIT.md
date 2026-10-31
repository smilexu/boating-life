# P1.0 基线审计

**状态：**PASS  
**阶段目标：**在任何鱼类行为代码/数据修改前记录当前三种鱼的 Profile、确定性生成机制、学校与渲染规则、存档兼容、F4/F3 入口，以及海鳟模型导入状态。

## 预计检查范围

- `scripts/fish_species_profile.gd`
- `scripts/fish_local_authority.gd`
- `scripts/fish_resource_manager.gd`
- `scripts/fish_school_renderer.gd`
- `scripts/fish_school_state.gd`
- `scripts/fish_resource_map.gd` / `scripts/fish_resource_map_canvas.gd`
- `resources/fish_species/*.tres`
- `assets/fishes/seetrout.glb`
- `tests/test_fish_resources.gd`、`tests/test_surface_fish_visibility.gd` 及鱼类工具
- bathymetry、WaveSampler、鱼类观测/调试入口

## 验收标准

- 三种旧鱼的 ID/index、学校生成和资源字段有可追溯记录。
- 测试执行前保存基线测试结果；未执行的检查标记 NOT RUN。
- 海鳟模型导入、Mesh/Surface、坐标朝向及材质状况有实测或明确限制。
- 记录存档 schema/layout 和现存 F3/F4 接入。
- 不在基线阶段改变鱼类行为。

## 检查记录

- 初始化：已读取 `docs/fish_species_ecology_audit.md`；其为静态审查，作为检查线索，不作为当前代码事实的替代。
- Godot CLI：4.7.2 stable。
- P1.0 代码基线、数据统计、命令和实测结果见下文。

## 修改前结构与数据流

- 主场景以 `FishResourceManager` 为入口，连接 `BathymetryManager`、`ShallowSeabedManager`、`WaveSampler`、`FishSchoolRenderer` 与 F4 `FishResourceMap`。
- `FishLocalAuthority` 以 700 m 网格、种子 `20261016`、布局版本 3 生成学校；每 8 s 推进一次、每帧最多处理 96 所学校。位置、学校 ID 和随机种子均以 `species_index` 参与确定性哈希。
- 当前 Profile 顺序为 needlefish(index 0)、herring(index 1)、three_spined_stickleback(index 2)。默认路径写在 `scripts/fish_resource_manager.gd::_load_default_profiles`。
- 权威学校人口是唯一生态数量来源；Renderer 的 MultiMesh 个体、表层涟漪和 F4 地图都是派生展示，不增加权威 population。needlefish/herring 深层学校仍保留权威状态，只切换为逻辑显示。
- 当前没有游戏鱼类持久化存档文件；学校可通过 authority snapshot 序列化。`FishSchoolState` 读取 schema 1/2，authority snapshot schema 1 要求布局版本和种子匹配。
- 当前没有项目级翻译目录、翻译 CSV/PO、`project.godot` 翻译注册或鱼类 `tr()` 使用。鱼类 F4 文本直接读取 Profile 名称/说明或脚本硬编码文本。
- `WorldTimeManager` 有单调推进的 `cycle_seconds`、`day_cycle_index`、`time_scale`、`paused`，可提供游戏时钟基准；鱼类管理器当前尚未连接该时钟。

## 三种鱼的兼容基线

基线由 `tests/test_fish_resources.gd` 的实际运行建立：

| species_id / index | 学校数 | 总 population | 学校规模 | 水深与活动层 | 视觉基线 |
|---|---:|---:|---|---|---|
| `needlefish` / 0 | 857 | 5,499 | 3–10：3尾117校、4尾100、5尾103、6尾116、7尾111、8尾120、9尾100、10尾90 | 海图可用2–42 m、偏好4–19 m；表层循环0.4–1.8 m、深层3.8–9 m；速度1.1–2.6 m/s | `needlefish.glb`，正X朝头；目标视觉长0.78 m、范围0.68–0.88 m、倍率2.5；表层份额0.55；视觉/逻辑阈值6 m |
| `herring` / 1 | 392 | 25,528 | Profile 范围35–96 | 海图可用8–53 m、偏好17–43 m；表层0.7–2.5 m、深层8–24 m；速度0.35–0.9 m/s | `herring.glb`，负X朝头；目标视觉长0.44 m、范围0.39–0.49 m、倍率2.5；表层份额0.40；movement state 为 schooling |
| `three_spined_stickleback` / 2 | 166 | 3,175 | small 14校(5–10)、common 133校(12–25)、large 19校(26–40)，按15%/75%/10%抽样 | 海图可用0.8–6 m、偏好1.3–3.3 m；浅水底栖/近表层目标走现有专用逻辑；速度0.1–0.34 m/s | Profile 模型，正X朝头；目标视觉长0.20 m、范围0.16–0.23 m、倍率1.0；F4 海草边缘色 |

学校位置以 `cell_x/cell_y`、world seed 和 layout v3 确定性哈希生成。运行结果未把全部逐校坐标保存成独立清单；现有测试用重复生成和快照断言验证位置/身份稳定。权重、规模、视觉长度均为游戏调校，不是本地普查数据。

## 模型与导入基线

- `assets/fishes/seetrout.glb` 为 2,931,832 byte 的 glTF 2.0 binary。起初无 Godot `.import` sidecar，故首次 `ResourceLoader.load()` 无法找到 loader。
- 运行 `godot --headless --path . --import` 后成功导入；GLB 源文件未修改。导入场景含一个 `MeshInstance3D`、一个 Mesh surface、一个材质；这符合现有 renderer 首 Mesh/surface 路径。材质/朝向需 P1.3 再核实。
- 导入器抽取了 GLB 材质引用的纹理与 `.import` sidecar；无海鳟导入错误。导入日志同时有旧 sailing telemetry `.translation` UID duplicate 警告，与鱼资源无关。

## 测试记录

| 命令 | 结果 | 备注 |
|---|---|---|
| `godot --headless --path . --script res://tests/test_fish_resources.gd` | PASS，`[FISH_TEST] failures=0` | 三鱼1,415校，确定性布局、DTM、学校快照、MultiMesh、模型测试通过；退出时出现 `DummyShader leaked` RID warning。 |
| `godot --headless --path . --script res://tests/test_surface_fish_visibility.gd` | PASS，`failures=0` | 深层逻辑鱼仍可在F4查到；渲染/地图操作未改变人口；同样出现 DummyShader RID warning。 |
| Godot Forward+ 图形目视模型检查 | NOT RUN | P1.0 只确认导入数据；稍后在 P1.3 尝试实际模型画面验收。 |

**P1.0 状态：PASS。** 此阶段没有修改运行时代码或旧物种 Profile。
