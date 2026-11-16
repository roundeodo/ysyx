# 整数执行单元

更新：2026-09-27。乘除单元由 [Issue 与 scoreboard](SCOREBOARD_DESIGN_RECORD.md)
管理独立请求与返回。本轮正在缩短结果返回端的组合路径，状态见
[发射与 FU 优化](../verification/ISSUE_FU_OPTIMIZATION_2026-09-27.md)。
初版集成结果保留于 [历史验证记录](../verification/SCOREBOARD_INTEGRATION_2026-09-26.md)。

## 范围与接口

2026-10-04 可读性复核：EXU 已选择的两个输入改称 `execute_operand_a_value` 和
`execute_operand_b_value`，不再用 rs1/rs2 暗示它们总是寄存器读值。
乘除专用输入为 `muldiv_operand_array_i`；ID/EX 保留既有的 load 返回先保存规则。
AGU 的地址计算、LSU 请求打包与请求有效性放在一起，普通结果选择另成一组。
乘法各级的组合计算和对应寄存器相邻，返回选择放在末级更新之前；电路行为不变。

EXU 连接组合 ALU、组合分支、三级流水乘法器和迭代除法器，支持 RV64M 的全部 13 条指令。
CSR 写值运算和 LSU 地址加法仍由 EXU 负责；BTB、地址宽度和缓存配置保持既有方案。

请求在 `valid && ready` 时被单元接收，同时分配 scoreboard 索引并释放 ID/EX。
操作数与运算类型由单元保存，不能依赖前级一直保持原指令。MUL 的索引随原有三级流水推进；
DIV 保存当前请求索引。结果接口独立返回索引与数值，反压时二者一起保持。

整核为普通 EX、MUL、DIV、LSU 分别预留完成入口，因此可以同拍接收不同指令的结果。
独立 MUL 可以连续进入乘法流水，DIV 在占用时只阻止下一条 DIV；年轻指令能否发射还取决于
程序顺序、源相关、串行化和队列容量，不能把单元吞吐直接当作整核 IPC。

提交异常会取消已发射单元的有效状态。分支纠错只取消尚未发射的年轻指令，保留较老乘除；
这是普通 EX 结果入口不反压、分支解析当拍禁止年轻发射的结果。改变这一边界时必须重新
设计年龄与取消规则。EXU 的 `issue_flush_i` 清当前发射上下文，`flush_i` 用于取消已发射乘除。

## 运算电路

ALU 共享加减/比较和移位电路。ADDW/SUBW 使用低 32 位计算并符号扩展；左右移位及 W 模式
通过输入格式、位序和最终格式化共享移位器。分支比较与目标加法独立，预测比较位于 EX 结果级。

乘法第一级用 16 个 `*` 计算 16×16 无符号部分积，给输入前递预留组合时序预算。
符号差异通过模 2^128 修正处理。三个内部寄存边界依次
保存部分积与修正项、进位保存压缩结果、低半部和及高半部的两种进位结果。
高半部和与高半部和加一并行计算，返回端只按已保存的低位进位选择，再处理 W 格式，
不在返回端串联 64 位自增器。结果进入 scoreboard 并参与前递。标识与格式使用同一使能。
只复位有效位，输出反压暂停流水；本轮没有再增加乘法运算级。

除法使用 radix-2 恢复余数算法。商与尚未处理的被除数共用移位寄存器，另保存除数、余数、
剩余位数、符号和格式。准备阶段处理除零、零被除数、除数绝对值为 1、被除数较小等情况；
准备阶段按最高有效位对齐被除数，跳过全部前导零；每拍仍只做一次试减。
请求先保存按 W/XLEN 格式处理的操作数。含负操作数时，ABSOLUTE_VALUE 状态
把它们转换为绝对值；非负或无符号操作跳过该状态。普通结果要求取负时，在
CORRECT_SIGN 状态写回原商/余数寄存器；无须取负则直接完成。
特殊值在准备阶段直接形成架构结果。返回端只选择已保存的数值，结果交付与下一请求可以同拍。
除零、最小有符号数除以 −1、
余数符号及所有 W 指令遵守 ISA，DIVUW/REMUW 的 32 位结果也要符号扩展。

并行乘法器与迭代除法器的面积不同，来自资源并行度与复用方式；多周期延迟本身不意味着
面积更小。当前乘法器不保证面积最优，替换运算结构必须同时比较周期、频率和面积。

## 寄存器与时序

| 状态 | 保存原因 | 规则 |
| --- | --- | --- |
| MUL 部分积、压缩结果、分半加法 | 运算流水与时序边界 | 相邻级及末级到 scoreboard/前递按单周期检查 |
| DIV 迭代数据与计数 | 每拍更新的算法状态 | 移位、比较、减法反馈按单周期检查 |
| MUL/DIV 指令索引 | 结果返回时识别所属指令 | 与运算载荷一起推进、保持和取消 |
| EXU 非分支纠错历史 | 防止未获准发射的同一指令重复纠错 | 发射或取消后清除 |
| Scoreboard 完成结果 | 年轻指令可先完成，架构更新仍按顺序 | 保留到提交；已完成结果可前递 |

原来用于防止重复启动的 `muldiv_request_occurred_q` 已移除：请求接收后即释放 ID/EX，
不再需要用一个历史位配合整条指令长时间保持。新增身份寄存器不增加运算级数。

没有为乘除添加多周期时序例外。只有输入在整个运算期间稳定、结果寄存器明确只在第 N 拍
采样的特定电路，才可研究对应起终点的 `set_multicycle_path`，并同时核对 hold 与采样边沿。
不能放宽每拍更新的迭代反馈、握手和取消路径。
参考 [AMD UG903](https://docs.amd.com/r/en-US/ug903-vivado-using-constraints/Multicycle-Paths)。

## 旁路与恢复

当前普通 ALU 结果保持直接前递，MUL/DIV 当拍返回和已保存结果通过 scoreboard 查询前递。
ID/EX 等待源的数据选择使用 FU 的 result_present，不把 flush 串进宽数据通路；
恢复仍禁止发射、禁止返回握手，并清除等待槽。
异常值不前递。同名写由 scoreboard 的最近写者标志选择来源，不要求等待前一条提交。

非分支错误 taken 预测仍提前恢复 PC+4，不等功能单元空闲。一位历史保证只纠错一次；
当前项尚未被接收时保留它，被接收时取消同拍年轻输入。较老恢复优先。

Issue 的 ready 按当前操作数和容量计算，不依赖随后可能被前端恢复撤销的 decoded valid，
避免把取消逻辑反馈成组合环。原 hazard controller 的组合等价结果仅属于旧实现；
本轮使用 scoreboard、Issue 与整核恢复测试，不能直接沿用旧形式证明。

## 历史测量与参考

改造前四级/三级乘法器比较中，同一 1024 条依赖 MUL 程序由 7226 拍降至 6203 拍。
这是加入 scoreboard 前的结果，不代表当前提交结构的周期数。原记录保留于
[执行单元初次接入](../verification/EXU_INTEGRATION_2026-09-26.md)。

参考机制按本核接口实现，没有移植其他项目整套 RTL：

- [CVA6 Issue/scoreboard](https://cva6.readthedocs.io/en/latest/04_cv32a65x/design/design.html#scoreboard)：
  独立事务标识、结果前递、乱序完成与顺序提交。
- [CVA6 multiplier](https://github.com/openhwgroup/cva6/blob/master/core/multiplier.sv) 和
  [serdiv](https://github.com/openhwgroup/cva6/blob/master/core/serdiv.sv)：乘除分离、符号处理与取消。
- [Ibex](https://ibex-core.readthedocs.io/en/latest/03_reference/instruction_decode_execute.html)：
  单元边界与多周期握手；不照搬其阻塞整个执行级的控制。
- [BOOM 执行级](https://docs.boom-core.org/en/latest/sections/execution-stages.html)：固定/可变延迟单元的接口；
  本轮没有引入其乱序发射、重命名或分支掩码。
- [VexiiRiscv](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Execute/plugins.html)：
  部分积分级、除法前导零跳过；没有移植 Scala 插件体系。
- [RISC-V M 扩展](https://docs.riscv.org/reference/isa/v20240411/unpriv/m-st-ext.html)：算术、边界与 W 指令语义。


## 2026-09-27 发射依赖与除法等待优化

基线保存在 `result/verification/issue-fu-optimization-20260927/`，本轮不运行 train。
现有 ID/EX 槽允许保存尚未就绪的源操作数及其生产者索引。槽中的指令仍按序发射，
未就绪时阻止年轻指令越过；LSU/MUL/DIV 正常完成值可在本周期直接供 EX 使用，
未交付时保存已返回的操作数。异常 LSU 结果不能唤醒；恢复清除等待有效性。
scoreboard 查询返回最近写者索引，当前 EX 尚未分配的生产者使用本次分配索引。
保留原有 ALU 直接前递、单未完成 LSU、顺序提交以及乘法三级流水。
除法器已在准备阶段按前导零归一化被除数，避免迭代阶段仍为高位零做试减。
重复/漏发、同名写、两源不同时间返回、反压、异常与分支恢复检查已通过。
完整 SoC 同镜像 MicroBench test 的 Scored 周期减少 4.18%，Total 周期增加 4.51%；
不能只引用前者宣称所有统计窗口加速，也不能推广为 train 结果。700 MHz 综合时序仍在验证。
完整条件、限制与原始记录见 [本轮验证报告](../verification/ISSUE_FU_OPTIMIZATION_2026-09-27.md)。
