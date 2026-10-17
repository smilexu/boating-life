# Phase 4B-2: København 港口与双港航线

## 实现范围

- `PortDefinition` 保存港口稳定 ID、WGS84 锚点、布局朝向、本地布局偏移、泊位、服务和水深覆盖配置。
- Malmö 保留既有 ID `malmo_greybox_v1`；København 使用既有货运合同目的港 ID `kobenhavn_test`。没有改写旧合同或存档中的 ID。
- 两座港口共用 `malmo_harbor_greybox.gd` 的灰盒生成、泊位交互、五点水深检查和服务菜单。København 场景通过独立 `PortDefinition` 配置其位置和旋转。
- København 测试锚点为 **55.6785302542° N, 12.6458850322° E**，位于 Prøvestenen 附近。真实港区在 CMP 官网列为哥本哈根港口码头区域之一，但本项目的泊位坐标、朝向、港池与建筑布局是游戏化摆放，未经测绘确认。[Copenhagen - CMP](https://www.cmport.com/terminals/copenhagen/)

## 水深与可靠性

两个港口各有独立的入口、港池、泊位多边形覆盖。København 覆盖仅为灰盒港区小范围测试数据：入口 4.0 m、港池 3.0 m、泊位 2.0 m；数据来源标为 `Gameplay-configured ... (unverified)`。Malmö 原有 ID 与配置保留。覆盖范围外仍使用 DTM 查询或 `Unknown`，不会被默认为安全深水。

现有 EMODnet DTM 2024 数据使用 LAT 基准，但本地栅格约 932×721，空间分辨率粗且岸边存在插值/无数据区域。它只能约束游戏原型，不构成海事导航水深或安全保证。航道覆盖和两条航线也没有进行真实海图、桥梁、交通、潮流或主管部门航路校验。

## 航线数据

航线作为 `RouteDefinition` 资源保存 WGS84 出发点、到达点及有序 `RouteWaypoint`。运行时经 `GeoReference` 转成 ENU 世界坐标，再按实际 XZ 路径段求和。每条路线状态为 `unverified_gameplay_route`。

| routeId | 主要航路点（WGS84） | 距离 | ETA（7 m/s） |
|---|---|---:|---:|
| `malmo_to_copenhagen_v1` | 55.6786458° N, 12.7776042° E | 约 21.910 km | 约 52.2 分钟 |
| `copenhagen_to_malmo_v1` | 55.6786458° N, 12.7786458° E | 约 21.906 km | 约 52.2 分钟 |

往返路线分别定义出港等待点、航路点和进港等待点，避免把一条路线简单倒放。ETA 使用 `StarterCargoBoat` 船型独立配置的 `cruise_speed_mps = 7.0`，不改变船舶 12 m/s 最大航速。估算不含进出港操纵、风浪及其他事件。

自动巡航阶段可调用：

- `PortRouteManager.get_route_between(origin_port_id, destination_port_id)`
- `RouteDefinition.get_world_points(georeference)`
- `RouteDefinition.get_total_distance_m(georeference)`
- `RouteDefinition.get_remaining_distance_m(world_position, georeference)`
- `RouteDefinition.get_estimated_travel_time_seconds(cruise_speed_mps, georeference)`

## 海图与调试

玩家持有任一跨港活动货运合同时，按 **F4** 打开现有海图即可看到相应预设路线、航路点、目的港、全程/剩余距离和参考 ETA；没有匹配的活动合同时不显示路线。地图折线由路线资源和同一 `GeoReference` 投影生成。

开发模式快捷键：

- **P**：前往 Malmö 灰盒测试点（既有功能）。
- **K**：前往 København 外港测试点。
- **O**：显示/隐藏港口泊位、水深与靠泊诊断。
- **G**：显示/隐藏双向路线、起终点、航路点顺序及调试文字。
- **E**：使用既有靠泊/离泊流程。

### 人工验证流程

1. 按 P 到 Malmö，按 O 查看港口诊断；在港口服务中接取 København 合同。
2. 按 F4 检查任务对应的路线及剩余距离。
3. 可按 G 查看世界空间路线和航点；按 K 到 København 外港测试点。
4. 从外港手动驶入，按现有距离、航速、航向、水深条件靠泊，再通过货运交易所交货。
5. 验证真实跨海峡驾驶时从 P 开始手动航行；K 是测试定位，不算真实航程。

本轮自动跨港交货测试用脚本设置船只与港口的测试位置，再调用正式接单、泊位校验、交货、奖励和存档接口。它验证业务闭环，不证明玩家已实际驾驶完成跨海峡航行。F4 图形表现、Forward+ 港口外观、手动航线可驶性仍需人工验收。
