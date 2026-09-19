> 历史记录，保留原文；当前说明见[同名文档](../TIMER_INTERRUPT_DESIGN_RECORD.md)。

# RV32 完整流水线定时中断

本设计基于 `rv32-interview` 的 bb03677，不使用旧单周期分支的后端空闲判断。

## 接口与范围

单 hart、本地 CLINT、M-mode 定时中断、mtvec Direct 模式。mtime 与 mtimecmp 为 64 位，RV32 软件分两次 32 位访问；mtimecmp 复位为全 1。MTIP 为 `mtime >= mtimecmp` 的硬件电平，MIE 与 MTIE 共同决定是否受理；软件写 mip 不清除 MTIP。外部中断、软件中断和 PLIC 不在本次范围。

参考：[RISC-V Machine-Level ISA](https://docs.riscv.org/reference/isa/priv/machine.html)。软件使用低半字先写全 1、高半字、最终低半字的顺序更新比较值，避免分次写入造成临时提前到期。

默认核时钟为 100 MHz，mtime 每 100 个周期递增一次，对应 1 MHz；它属于平台时间基准，不是 mcycle。当前定时器与 CPU 同时钟域。

| 地址 | 寄存器 |
| --- | --- |
| `0x02000048` / `0x0200004c` | mtime 低 / 高 32 位，保留原 uptime 地址 |
| `0x02004000` / `0x02004004` | mtimecmp 低 / 高 32 位 |

只支持对齐的 32 位单拍寄存器访问，支持字节写使能；不支持的地址、尺寸和 burst 返回 SLVERR。读/写响应在背压期间保持不变。这里是本项目的地址映射，不宣称兼容所有平台的 CLINT 地址布局。

## 精确受理

`interrupt_controller` 只保存恢复 PC 和产生暂停/受理条件，CSR 状态仍由 csr_file 管理。待处理中断阻止 register_read_stage 向 decode_execute_stage 交付新指令；已进入执行级的工作继续推进。execute_packet、execute_result、LSU、writeback 都为空，数据缓存与 FENCE.I 维护完成，且无前端重定向待应用时，才能受理。

恢复 PC 只按提交的 next_pc，以及提交点同步异常/mret/中断的目标更新。执行级推测纠错不能更新架构恢复 PC。同步异常和 mret 的提交拍先于中断处理；CSR 写入和 mret 后直接重新检查使能，不锁存已经撤销的请求。中断不伪造退休指令，不增加 minstret。

受理时经 trap_controller 写入 mepc、mcause（RV32 为 0x80000007）、mtval=0，保存 MPIE 并清除 MIE，清空年轻流水项并重定向。未完成的 AXI 请求不撤销，取指返回由既有 epoch 机制丢弃。对已发出的访存，中断延迟取决于总线完成时间。

## 验证计划

复用并适配 CLINT/控制器单元测试、汇编自检与 AM 定时事件程序；系统测试启用本分支真实流水线和 D-cache，加入 AXI 背压及错误返回，核对提交 PC、恢复 PC、访存指令次数和退休计数。随后运行已有流水线、特权、访存和缓存回归。普通 DiffTest 尚无异步中断注入，本回归使用独立系统测试平台，不声称已验证中断差分流程。

## 回归发现的 FENCE.I 边界修复

加入缓存冲突和 FENCE.I 的完整系统自检后，历史实现触发了 I-cache 的 `a_lookup_request_stable_while_stalled`。原因是维护状态直接屏蔽请求 valid，撤回了已经对外可见的背压请求。当前增加一位“请求正在背压”状态及 DRAIN 阶段：保持旧请求直到握手，等待 I-cache 排空，然后清理 D-cache 并使 I-cache 失效。保留原稳定性断言，用同一系统场景复查。

## 完整系统结果（2026-09-05）

配置：`rv32-baseline`，I-cache 256 B/1 路/16 B 行，D-cache 256 B/2 路/16 B 行，Verilator 5.043 devel，启用 SVA。

| 程序 | AXI 附加延迟 | 结果 | 中断次数 | 外部写回数据拍数 | 中断 pending 与写事务重叠周期 |
| --- | --- | --- | --- | --- | --- |
| 汇编自检 | 0 | 通过 | 11 | 3976 | 173 |
| 汇编自检 | 17 | 通过 | 11 | 2008 | 391 |
| 汇编自检 | 83 | 通过 | 11 | 448 | 635 |
| AM C 程序 | 0 | 通过 | 5 | 4 | 0 |
| AM C 程序 | 83 | 通过 | 5 | 4 | 0 |

合计 43 次中断。三个汇编场景均执行了脏替换与 FENCE.I，并检查 pending 在访存错误等待期间出现、同步异常优先完成、mret 后重新响应。错误读人为延迟 6000 个周期，软件预留 20 个 mtime tick（2000 个核周期）才到期，避免冷 I-cache 延迟使请求在访存发出前就触发。表中写回拍数不等于 store 指令条数；测试另行核对 LSU 接受与提交的 store 指令数量，并以程序读回检查数据。

复现（恢复工作目录下）：

```bash
export NPC_HOME="$PWD/npc"
make -C npc NPC_CONFIG=rv32-baseline git_commit= test-timer-interrupt
make -C npc NPC_CONFIG=rv32-baseline git_commit= lint-npc
make -C npc -k -j2 NPC_CONFIG=rv32-baseline git_commit= \
  test-privileged test-pipeline test-lsu test-dcache test-uncached test-core-merge
```

系统及单元日志保存在 `npc/build/tests/interrupt/`，汇总日志在 `npc/build/interview-audit/timer-regression.log`。已有六个模块回归通过；整核 lint 退出码为 0，仍有未使用信号/参数等告警，没有 LATCH、UNOPTFLAT、MULTIDRIVEN 或 PINMISSING 告警。此次未重测面积、频率，未运行完整 ysyxSoC/RT-Thread，也未接通异步中断 DiffTest 同步。

CLINT、interrupt_controller、IFU 与真实预测器连接的三个 RTL 单元测试均通过。完整入口最终退出码为 0：5 次程序运行 + 3 个 RTL 单元测试，共 8 项。CLINT 检查比较边界、重新定时、64 位比较、字节写、W 先于 AW、R/B 背压及非法 burst；控制器检查空闲受理、排空、撤销、维护、提交互斥及架构 PC；IFU 检查背压、连续重定向和旧响应排空。
