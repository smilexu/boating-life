# Malmö 港口服务菜单 · Milestone 5 Phase 3

## 状态与职责

- 城市港口使用通用入口交互：距城市模型最近外轮廓 500 m 内显示距离，200 m 内且航速不高于 0.8 m/s 后按 **E** 进港。水深不作为进港条件。它不执行靠泊、不吸附船只、不设置 `BoatController.is_port_docked`，只暂停船只运动并打开服务菜单。各城市可配置距离和速度阈值；Malmö 当前使用 500 m / 200 m / 0.8 m/s。
- 哥本哈根仍使用原有泊位、航速、航向和泊位水深校验。两个港口通过各自的状态信号与复用的菜单控制器交互。
- 菜单不暂停世界时间、海面、天气或昼夜。Malmö 菜单主页面关闭或选择“离港”会退出城市入口并恢复进入前的船只暂停状态；船只位置不变。
- `PortServiceController` 维护 `SAILING`、`DOCKED`、`PORT_MENU` UI 状态，复用同一个 CanvasLayer 菜单实例。
- `PortServiceConfig` 只提供港口 ID、显示名、服务 ID、服务显示名和开放状态。未来港口可以挂接自己的 `.tres`，不需要复制菜单组件。
- 服务面板只显示当前已接入的数据；当前燃油、维修、交易和购船业务系统均未实现。

## Malmö 服务配置

配置文件：`resources/ports/malmo_port_services.tres`

包含服务 ID：`cargo_exchange`、`fuel`、`shipyard`、`ship_market`。标签和开放状态均由资源配置，不在 UI 中写死 Malmö 名称或服务清单。

当前测试船名由 `resources/vessels/test_sailboat_draft.tres` 的 `vessel_display_name` 提供。

## 操作

- Malmö 满足城市入口条件时按 **E**：打开港口服务主菜单，船只保留在当前位置。
- 哥本哈根满足原有靠泊条件时按 **E**：进入停泊态并自动打开港口服务主菜单。
- 点服务卡片：打开对应占位面板；在子面板按 **Esc** 或“返回服务菜单”回主菜单。
- 哥本哈根主菜单按 **Esc** 或“关闭菜单”：仅关闭 UI，船仍停泊；按 **F** 重新打开菜单。
- Malmö 子面板按 **Esc** 回到主菜单；在主菜单按 **Esc**、点“关闭菜单”或“离港”：退出进港状态并恢复船只运动。
- 菜单打开时 **E 不会离港**。

打开菜单会释放右键镜头捕获并显示鼠标；关闭后继续显示鼠标，右键拖动可以重新观察。

## 当前占位内容

- 货运交易所：可接任务与已接任务为空，不生成虚假任务或报酬。
- 燃油补给：容量、余量和补给均标记为尚未接入。
- 维修船厂：耐久度和维修均标记为尚未接入。
- 船舶市场：显示当前船舶及暂无可购买船舶。

## 自动验证

```sh
godot --headless --path . --script res://tools/test_port_services.gd
godot --headless --path . --script res://tools/test_malmo_harbor_greybox.gd
godot --headless --path . --script res://tools/test_navigation_depth.gd
```

这些测试检查服务状态与 Phase 1/2 逻辑，不替代 Forward+ 下的实际菜单视觉和鼠标体验验收。
