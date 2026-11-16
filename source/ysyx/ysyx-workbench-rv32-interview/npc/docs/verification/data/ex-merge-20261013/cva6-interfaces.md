# CVA6 执行接口核对

2026-10-14 核对 OpenHWGroup CVA6 master；不同命名配置不能统一推断延迟或缓存能力。

| 单元/边界 | 实际源码 | 对本轮的约束 |
| --- | --- | --- |
| branch unit | `always_comb` 完成目标、预测校验、异常；没有独立 ready 端口；接收 ALU 的一位比较结果 | 单级分支解析有真实项目依据，不因 valid 端口增加结果级 |
| ALU/branch 完成 | `ex_stage` 的 one-cycle 路径组合汇合，返回结果和 transaction ID | 接口与流水级分开；本核没有 scoreboard，仍需阻止年轻结果越过老 LSU |
| LSU bypass | 缓冲为空时组合直通，受阻时保存请求；ready 来自已寄存占用 | 只为确有时序/在途身份需要的事务保留状态；不强制所有请求先排队一拍 |
| load/store | 接收请求与 load/store 完成是不同接口，另有 store commit 信号 | 入口握手不是内存访问完成；不能从 ready 推断 hit 延迟或 miss 延迟 |
| CSR buffer | 单项 CSR 地址及存在位；operand_a 先作为待提交操作数进入 scoreboard，地址保留到 commit，flush 清存在位 | 这是提交上下文，不是 CSR 计算流水级；本核 CSR 地址已随 uop 到 WB，不能盲目复制一套状态 |

`valid`、`ready`、`grant` 的语义须一起核对产生端和接收端。CVA6 的部分 FU valid
是已发射操作的通知，不能仅按信号名假定其内部接口都等同于本核的 held-valid/ready 协议。
延迟、发射间隔、在途容量、提交条件分别检查；握手不自行产生寄存器或周期。

`commit_stage` 的 CSR 分支才产生实际 `csr_op/csr_wdata`，并将 `csr_rdata` 写回 GPR。
因此不能把 buffer 的 `csr_result_o` 当成已经读出的 CSR 旧值。

## Branch unit 的电路边界

`ex_stage` 将 ALU 的 `alu_branch_res_o` 接到 branch unit 的 `branch_comp_res_i`。
这是一个条件是否成立的位，不是 XLEN 位整数结果。ALU 中 EQ/NE 使用减法零标志，
有符号/无符号大小判断与 SLT 类运算共享比较逻辑。

branch unit 自己计算目标：B/J 使用 PC+立即数，JALR 使用 rs1+立即数并清 bit 0；
另算 PC+2/4 作为顺序地址和链接地址。条件比较与目标加法并行，随后汇合生成实际
方向、恢复地址、预测错误信息和目标未对齐异常。`branch_result_o` 是链接地址，
不能误读成跳转目标。

当前 `branch_unit.sv` 只有组合过程，无内部寄存器或独立 ready；`ex_stage` 也明确
标注 branch unit 为 combinatorial。拆成模块没有增加一拍，也没有形成独立于 ALU
的条件比较执行资源。

工程判断：这条边界把 PC、预测信息、恢复和异常处理集中起来，同时复用 ALU 比较，
方便阅读和验证；这是根据电路组织作出的解释，不是作者明示的全部设计动机。
本核对应逻辑目前在 EXU 内，同样可以保持单级 EX。抽成组合模块本身不保证面积或
频率改善，不能借此重新加入结果寄存级。

一手入口：[branch_unit](https://github.com/openhwgroup/cva6/blob/master/core/branch_unit.sv)、
[alu](https://github.com/openhwgroup/cva6/blob/master/core/alu.sv)、
[ex_stage](https://github.com/openhwgroup/cva6/blob/master/core/ex_stage.sv)、
[lsu_bypass](https://github.com/openhwgroup/cva6/blob/master/core/lsu_bypass.sv)、
[load_store_unit](https://github.com/openhwgroup/cva6/blob/master/core/load_store_unit.sv)、
[csr_buffer](https://github.com/openhwgroup/cva6/blob/master/core/csr_buffer.sv)、
[commit_stage](https://github.com/openhwgroup/cva6/blob/master/core/commit_stage.sv)。
