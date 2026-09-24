# RV32 M-mode 定时器中断

本实现基于 Git `a6f6cc0`，位于独立分支 `rv32-timer-interrupt`。这是带 I-cache、
阻塞式非缓存数据通路的历史 RV32 基线，不包含当前工作目录的 RV64 流水线和 D-cache。

## 接口与行为

- CLINT 保留 `mtime` 的原地址 `0x02000048/4c`，增加 `mtimecmp` 的
  `0x02004000/04`。寄存器采用对齐的 32 位 AXI 单拍访问，写入按 WSTRB 更新。
  `mtime` 和 `mtimecmp` 都是 64 位，比较采用无符号数；比较值复位为全 1。
- `timer_interrupt_o` 是同一时钟域的电平请求，直接连接 CPU。软件更新比较值使
  `mtime < mtimecmp` 后请求撤销。仅支持机器定时器中断，不含 MSIP、外部中断或 PLIC。
- CSR 的 `mip.MTIP` 由硬件驱动，不允许软件清除；`mie` 仅实现 MTIE。
  本核只运行 M-mode，MSTATUS 仅实现 MIE/MPIE，MPP 固定为 M。
  MTVEC 仅支持 Direct 模式，MEPC 按 4 字节对齐。
- `interrupt_controller` 在请求和使能同时有效时停止向 EXU 送入新指令；LSU 继续运行。
  LSU 空闲且 I-cache 维护完成后，向已有 trap controller 发出独立中断事件。
  不伪造指令提交，不增加 minstret，也不产生 GPR 或访存副作用。
- 本基线的 EXU、completion 和 commit 都是组合路径，只有 LSU 能保存未完成的后端指令。
  因此这里的安全条件不能直接移植到增加了流水寄存级或 D-cache 的版本。
- 控制模块跟踪已完成指令的实际 next PC，并优先记录选中的重定向目标，包括分支、
  同步异常、mret 和中断入口。没有有效取指或提交时，也能使用该 PC 接收中断。
- 中断进入写入 `mcause=0x80000007`、`mtval=0`、正确的恢复 PC，并保存和关闭 MIE。
  同步访存异常先通过原路径处理；等待期间始终重新检查请求和使能，不锁存过期请求。
- 已接受的 AXI 事务继续完成；前端通过既有 redirect 丢弃旧控制流结果。
  中断延迟依赖访存响应时间，不承诺固定周期上限。

## 软件与验证

RV32 更新比较值采用低字写全 1、高字写新值、低字写新值的顺序，避免中间值提前触发。
中断处理程序保存所用寄存器、重新设置下一次定时，再执行 mret；中断不能将 mepc 加 4。

验证必须覆盖真实 RV32 指令执行、周期定时、屏蔽/重新使能、mret、访存等待、同步异常、
分支和空闲取指边界，以及 CLINT 的 AXI 反压、字节使能和非法访问。
实际通过项和命令在完成测试后记录；不将定向测试等同于 RT-Thread 或完整 SoC 验证。

## 本次联调发现的前端问题

AM C 程序在首次定时器中断前触发了历史 IFU 缺陷：旧 lookup 在 redirect 后才握手时，
IFU 用旧 PC+4 覆盖了已保存的恢复目标。独立测试在修复前得到 `0x80000004`，
预期为最新重定向目标 `0x80002000`。原始失败保存在
`build/tests/interrupt/ifu_before.log` 和 `am_before_ifu_fix.log`。

修复只在请求 epoch 仍属于当前控制流时更新顺序 PC；过期请求继续完成并丢弃响应。
测试覆盖请求反压、连续两次重定向、延后的请求握手及旧响应排空。

## 运行方式

在此分支的 `npc` 目录执行：

```sh
python3 tests/interrupt/run.py
```

需要 `verilator`、C++ 编译器、Python 3 和 `riscv64-linux-gnu-gcc/objcopy`。
脚本生成 RV32 ELF/镜像、编译 testbench、执行 SVA 和自检；构建和运行日志保存在
`build/tests/interrupt/`。也提供 `make test-timer-interrupt` 入口。

软件示例：

- `tests/interrupt/timer_interrupt.S`：CSR、精确返回地址、访存错误和周期定时的汇编自检。
- `tests/interrupt/am_timer.c`：使用本项目 `cte_init`、`iset`、`ienabled` 和 `yield`，
  由原有 `trap.S` 保存/恢复上下文，由 `cte.c` 派发 `EVENT_IRQ_TIMER`。
  处理程序负责重新设置比较值；示例中的短时间计时不作为通用 64 位定时驱动。

## 验证边界

本次回归使用完整 RV32 核、本地 CLINT、内部 AXI 互联及带反压和错误注入的外部内存模型。
它不依赖 NEMU，也不声称完成中断 DiffTest：历史 NEMU 的 `difftest_raise_intr` 仍为断言占位，
CSR 模型也不完整。使用历史 `--diff` 入口不能验证本次定时器程序。

未验证 RT-Thread 的定时抢占、完整 ysyxSoC、FPGA/芯片运行、PPA，未增加软件中断、
外部中断或向量入口。原先的 RV32 面积与频率测量不能直接用于新增中断后的配置。

## 2026-09-05 验证结果

命令：`cd npc && python3 tests/interrupt/run.py`，退出码 0；Verilator 启用 `--assert`。

| 测试 | 结果 |
| --- | --- |
| 汇编自检，访存基础延迟 0 / 17 / 83 周期 | 3/3 通过，每次 11 次定时器中断 |
| AM C 程序，访存基础延迟 0 / 83 周期 | 2/2 通过，每次 5 次定时器中断，另含一次 yield/ecall |
| CLINT AXI 与寄存器测试 | 通过 |
| 中断控制：空闲接收、等待访存/维护、请求撤销、分支/异常返回 PC | 通过 |
| IFU：反压中的取指、连续重定向、旧事务握手与响应 | 修复前失败，修复后通过 |
| standalone top、SoC CPU wrapper、综合 filelist 的 Verilator lint | 通过，无 warning/error |

汇编三组测试均观察到中断在 load/store 等待期间有效、访存错误响应与中断竞争，
以及没有有效前端指令时接收中断。每次中断进入都检查恢复 PC，每条提交都检查 PC 连续性；
实际外部内存写次数与已提交 store 数量相等，minstret 与正常退休数相等。

系统测试合计接收 43 次定时器中断；这是此次定向回归的计数，不代表随机验证覆盖率。
详细日志在 `npc/build/tests/interrupt/`，覆盖条件由测试断言和计数器共同记录。
