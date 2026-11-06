# Sabiki 收线折角代码审查记录

> 记录上一轮对“串钩收线时鱼线仍出现折角”的只读代码审查结论。审查范围仅限代码静态检查；未修改游戏代码，也未运行测试或实际场景复现。

**代码里确实存在多套线形判断，但没有为串钩做一套独立的分段张力求解器。**权威线长仍是同一个 `_line_paid_out_length_m`；搏鱼时单钩和串钩也共用 `BoatFishingFightSolver`。但从“实际怎么收线”到“画面怎么画线”，两者并没有完全共用一条路径。

主要区别在显示层：

- 外部鱼线由一组路径点逐段生成网格。松线时还可能插入船舷避让点，形成折线路径；相关路径构造在 [boat_fishing_casting_system.gd](scripts/boat_fishing_casting_system.gd#L4522) 和 [同文件的船体避让路径函数](scripts/boat_fishing_casting_system.gd#L4270)。
- **Sabiki 有专属的松线末端贝塞尔曲线**，单钩走通用下垂曲线；是否进入这条分支又取决于钩组类型、绷紧状态和船体路径是否允许，见 [boat_fishing_casting_system.gd](scripts/boat_fishing_casting_system.gd#L4575) 和 [Sabiki 曲线函数](scripts/boat_fishing_casting_system.gd#L4640)。
- Sabiki 的主线是另一个独立的圆柱模型，五个钩和支线也分别绘制；外部鱼线网格与这个钓组模型只在连接点衔接，见 [Sabiki 模型生成代码](scripts/boat_fishing_casting_system.gd#L5157)。
- 线形是否绷紧会随状态切换：手动收线标记、钓组是否已出水、搏鱼状态和回收状态都会参与判断，见 [绷紧状态判断](scripts/boat_fishing_casting_system.gd#L4726)。钓组整体出水时，系统会同时让外线转为松弛，并逐渐让 Sabiki 钓组转向垂直，见 [出水状态切换](scripts/boat_fishing_casting_system.gd#L3911) 和 [钓组方向计算](scripts/boat_fishing_casting_system.gd#L4739)。

收线也有状态差异：等待时手动改变线长并按几何约束拉动钓组；搏鱼时由 Solver 决定线长变化；最后回收动画则插值移动钓组并同步线长。这些不是串钩的分段力学，但意味着不同阶段可能切换到不同的线形与位置更新逻辑。

这也解释了为什么之前改过多次仍会看到折角：先前的修改集中在**湿态下让 Sabiki 主线方向对齐竿尖—铅坠方向**，修复了那一种折角；但松线贝塞尔、船舷避让路径、出水后的方向松弛，以及外部线网格和 Sabiki 圆柱之间的衔接仍是不同分支。此前报告记录的几何断言通过的是特定状态，且没有完成 Forward+ 实际画面验收，不能证明所有收线状态都没有折角。[P6.3.2 报告](P6_3_2_SABIKI_MULTI_CATCH_REPORT.md#L50)

**仅凭这张截图和静态代码，无法确认当时具体命中了哪条分支。**但可以确认，你期望的“单钩和串钩共用一致的主线物理，串钩只增加钩位”，目前在求解器层基本成立，在显示路径和钓组几何层则没有完全成立。尤其在松线或钓组出水的转换过程中，存在多套独立判断，值得作为这次折角持续出现的重点嫌疑。

本轮只做了代码审查；**没有修改代码，也没有运行测试或实际场景复现**。
