# RV32 定时器与精确中断

单 hart、M-mode 定时中断、mtvec Direct 模式。没有 MSIP、外部中断控制器或 PLIC。

## 电路结构与源码顺序

| 模块 | 结构与状态 |
| --- | --- |
| `axi4_clint` | 分频计数与 mtime 更新 → mtimecmp 字节写 → AXI 输出 → 读事务 → 写事务 |
| `interrupt_controller` | 一个架构恢复 PC；组合暂停/受理条件 → 按架构恢复或提交更新 PC |
| `csr_file` | MIE、MPIE、MTIE 及 trap CSR；读值重建与合法性检查 → 优先处理 trap、mret、软件写 |
| `trap_controller` | 组合选择同步异常、mret、定时中断，产生 CSR 更新及重定向 |

CLINT 的 64 位 `mtime` 自动递增，软件写优先于该拍递增；零字节写使能不阻止计时。
`mtimecmp` 复位为全 1，`mtime >= mtimecmp` 直接形成电平中断。MIE 与 MTIE 共同决定
核是否受理；软件写 mip 不清除这个电平。

核与 CLINT 共用输入时钟。`CLINT_CLOCK_FREQ_HZ / MTIME_INCREMENT_FREQ_HZ` 决定递增间隔，
默认参数为 100 MHz 输入、1 MHz 递增；运行时必须让参数与所采用的核频率一致。
默认参数不代表存在独立的 100 MHz 时钟引脚。计时口径见[测量规则](../verification/MICROBENCH_TIMING_RULES.md)。

## 访问与反压

RV32 用单拍 32 位访问两个半字。读 mtime 低半时保存完整快照，随后的高半读取得该快照并释放，
避免半字读取之间溢出。软件分次更新 mtimecmp 时，先将低半写全 1，再写高半和最终低半。
具体地址由 `riscv32_addr_map_pkg` 定义。

AXI 读写各有独立状态。AW 先保存地址和访问合法性，W 按字节使能更新寄存器，最后返回 B。
不支持的访问返回 SLVERR，非法 burst 仍消耗或返回全部 LEN+1 拍；反压期间保持响应。
计数、比较、响应寄存与快照各自保存必要状态，不因模块拆分增加寄存级。

## 精确受理

待处理中断阻止译码/操作数准备向 ID/EX 交付新指令，已经进入后端的工作继续完成。
执行包、执行结果、LSU 和 WB 全部排空，D-cache 与 FENCE.I 维护结束，且没有待应用的
前端重定向时，控制器才受理。受理还与当前提交互斥，同步异常和 mret 优先处理。

恢复 PC 只由提交的 next_pc 或架构重定向更新，执行级推测纠错不能修改它。
受理时写 mepc、mcause、mtval，保存 MPIE 并清 MIE，再重定向至 mtvec；不伪造退休指令。
已发出的 AXI 事务继续完成，旧取指响应通过 epoch 丢弃，中断延迟因此受存储响应时间影响。
FENCE.I 的请求保持与清理次序见[流水线说明](PIPELINE_DESIGN_RECORD.md)。

## 验证入口

`make -C npc git_commit= NPC_CONFIG=rv32-baseline test-timer-interrupt` 包含
3 组汇编系统测试、2 组 AM 程序测试和 3 个 RTL 单元测试，启用反压与断言。
普通 DiffTest 尚未注入异步中断；本测试使用独立系统平台核对恢复 PC、访存次数和退休数。
当前结果见[可读性验证](../verification/RV32_READABILITY_2026-09-16.md)，
[历史测量](archive/TIMER_INTERRUPT_DESIGN_RECORD_BEFORE_2026-09-16.md)仅供追溯。
