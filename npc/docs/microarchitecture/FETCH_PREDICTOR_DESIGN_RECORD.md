# 取指预测器：原理与电路结构

当前实现，2026-09-23。查询只有一个响应寄存级；与 IFU 的连接见
[前端总览](FRONTEND_REWRITE_DESIGN_RECORD.md)。

## 模块职责

| 模块 | 拥有的状态与功能 |
| --- | --- |
| `riscv32_branch_predictor` | 解析事件组合分类；并行查询结果选择；唯一响应寄存器及统一握手 |
| `riscv32_bht` | 两位饱和计数器数组、组合查询、条件分支同步训练 |
| `riscv32_btb` | tag/target/kind、有效位、替换状态；组合查询与训练选路、同步写入 |
| `riscv32_ras` | 返回地址数组、写指针、数量；组合读取栈顶 |

父模块源码先列训练入口，再列共享的三个表、查询选择与响应寄存器。
训练和查询是并行路径，BHT、BTB、RAS 之间没有串联寄存级。
BHT 默认按 PC 索引两位饱和计数器；BTB 按组并行比较各路 tag；RAS 保存已解析调用的返回地址。
可选 gshare/Bi-mode 的历史和查询快照见[方向预测原型](DIRECTION_PREDICTOR_DESIGN.md)，
由 `BRANCH_DIRECTION_POLICY=1/2` 启用，默认0；查询仍只有一个响应寄存级。

## 查询时序

BHT、BTB、RAS 同时对当前请求给出组合结果。BTB miss 选择不跳转；条件分支取 BHT 最高位；
直接/间接跳转预测 taken；返回优先使用非空 RAS，否则使用 BTB 目标。目标不满足四字节对齐时禁止 taken。
父模块在请求握手沿 E0 保存 PC、epoch 和完整预测，E1 可由 IFU 消费。
响应可在同沿被消费和替换，反压期间保持完整载荷。flush 优先清有效位并拒绝新请求。
`next_pc` 由已保存的 PC 和预测组合产生，不另存一份重复地址。

当前 IFU 消费 taken 响应时直接查询目标，连续命中跳转的目标请求间隔为一拍。
这是前端接口间隔，不等于每次分支的退休停顿。

## 训练时序与清除

训练来源为 EX 结果寄存器中无异常控制流指令的交付事件。解析信息直接驱动三个单元，
在交付沿更新表项或栈；不再保存一份训练 payload，也不等待 commit。
BTB 当拍直接读取当前数组，优先同 tag，再空 way，默认最后轮转替换；连续同 set 写入不需要
待写事务旁路。查询和训练同沿时仍使用旧表值，不把 EX 结果组合旁路到查询端。

`BRANCH_TARGET_POLICY=0` 保持原行为；实验策略1/2/3分别测试准入过滤、taken 复用 RRIP
和两路 LRU，均不增加查询寄存级或训练等待，BHT/RAS 训练也不由 BTB 准入关闭。
具体状态和更新规则只在[BTB 策略说明](BTB_POLICY_DESIGN.md)维护；实验机制默认关闭。

默认策略复位使 BHT 计数器为 01，清 BTB 有效位和替换指针，清 RAS 数量与指针。
invalidate 清 BTB、RAS，BHT 保留计数器；启用历史预测时另清已解析历史，该沿不接受新训练。
flush 只取消查询响应，不清训练状态。系统发起 fence.i 时负责协调两类清除。
表项和响应的无效载荷不复位；查询有效位、表项有效位和 RAS 数量决定何时可以使用载荷。

## 关键取舍

组合查表减少查询延迟，但索引、比较和目标选择必须在一个周期内完成。
训练路径从 EX 结果寄存器开始；RAS 只根据已解析结果更新，不需要推测检查点，
代价是新调用/返回不会在查询时立即改变栈。满栈 push 覆盖最旧项，空栈 pop 无操作。

## 验证入口

- `make -C npc git_commit= NPC_CONFIG=rv32-baseline test-predictor`：当前 RTL 与独立模型比较。
- `make -C npc git_commit= NPC_CONFIG=rv32-baseline test-fetch`：真实 IFU 与预测器的 taken 间隔。
- `test-predictor-equivalence`：回放两个冻结提交的历史拆分等价测试，不验证当前单级实现。
- 分支实验见[首轮记录](../verification/BRANCH_EXPLORATION_2026-09-22.md)和[负载与历史预测补充](../verification/BRANCH_FOLLOWUP_2026-09-23.md)。
- 此前流水线优化的全核、缓存、计时和 PPA 见[历史验证记录](../verification/RV32_CYCLE_OPT_2026-09-19.md)。


## 目标地址编码实验入口（2026-09-23）

默认BTB结构保持不变。`BRANCH_TARGET_WAY_BITS=0`走原实现；非0时实例化按路保存目标低位的
`riscv32_compact_btb`，接口与响应级不变。电路、范围限制和恢复规则见
[目标存储设计](BTB_TARGET_STORAGE_DESIGN.md)，实测取舍见
[本轮实验](../verification/BRANCH_TARGET_EXPLORATION_2026-09-23.md)。原型不默认启用。
