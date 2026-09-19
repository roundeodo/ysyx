# RV32 精确异常修复与综合验证

对象：`rv32-interview-20260911`，基于 `71b5935c100c264313ebc35d3549b1f3ae354b34` 的修复。
配置：`rv32-baseline`。本轮完成定向复现、修复、功能回归和实际综合/STA，仅作本地提交。

## 问题与修复

问题已在整核仿真中复现：非法指令或跳转目标未对齐异常留在 EX 结果级时，年轻 store
可以在老异常进入 WB 的同拍被 LSU 接收。下一拍 WB 的 flush 无法取消这笔请求；原版本
确实发出了 AXI 写，并错误提交了 store。此前从 WB 开始构造异常的测试没有覆盖这个窗口。

修复在冒险控制中增加 `EX 结果有效 && 该结果有异常` 这一组合阻塞条件：保持年轻 ID/EX
指令，禁止 EXU 发射及 LSU 接收；老异常自身仍可进入 WB，由提交恢复统一清空年轻指令。
只修改 hazard 与 core 的连接/断言，没有新增流水级、寄存器或 LSU 取消接口。
正常结果以及 valid=0 时残留的异常字段不会触发这个阻塞。

| 原失败用例：非法指令后接 store | 修复前 | 修复后 |
| --- | --- | --- |
| 第 108 拍 EX 异常与年轻 store 重叠 | LSU 接收 store | 保持年轻指令，不发射 |
| 第 109 拍 WB 触发异常恢复 | 数据通路接收 store | LSU 空闲，无访存请求 |
| 最终写入 / 年轻 store 提交次数 | 1 / 1 | 0 / 0 |
| 地址 `0x0f000004` 的内容 | 被改为 `0x55` | 保持 `0x12345678` |

## 验证结果

| 检查 | 结果与范围 |
| --- | --- |
| 整核精确异常定向测试 | 32/32 通过：NOP、非法指令、未对齐 JAL、ECALL × 年轻 load/store × uncached SRAM/MMIO × 老 load 延迟 0/80 拍 |
| 流水控制测试 | RV32、RV64 均通过；覆盖结果反压、无效异常字段、正常指令继续执行及 WB 年龄优先级 |
| CPU DiffTest | 实际 35 个测试程序全部通过 |
| 定时中断回归 | 8/8 通过，包含系统、CLINT、中断控制及 IFU 恢复测试 |
| lint / 综合检查 | RV32 NPC/SoC lint 通过；Yosys CHECK 0 个问题；复位缓冲结构等价与连通性检查通过 |

整核测试执行真实指令，不强制内部流水线状态；同时检查 LSU 接收、AXI 读写、提交和存储
内容。非串行化异常的 80 拍用例还要求实际出现 EX 异常与年轻访存重叠，避免未触发场景却通过。
正常 load/store 是正向控制用例，确保修复没有简单地阻止所有访存。

首次 DiffTest 启动遇到本地 Capstone 路径和旧 P3 列表缺少 `csr-trap` 源文件的问题；修正
库路径后运行现有 35 个程序，并逐项检查 PASS/FAIL。原失败日志保留。未运行 formal 或
microbench，不能据此给出新的 IPC/train 用时；旧 formal harness 也不作为本轮通过证据。

## 面积与时序

沿用[上次测量](RV32_READABILITY_PPA_2026-09-19.md)的冻结工具、NanGate45 typical 库、
820 MHz 综合约束和 `DELAY 0` 策略。I-cache 为 256 B / 1 路，D-cache 为 256 B / 2 路，
cacheline 16 B；BHT 16 项、BTB 16 项 / 2 路、RAS 4 项。面积包含纯核、复位控制和
63 个复位缓冲单元，不包含 SoC；数组映射为标准单元，时序尚不包含布局布线寄生参数。

| 指标 | 上次测量 | 本次修复后 |
| --- | ---: | ---: |
| 标准单元面积 | 73,037.748 μm² | 73,081.372 μm² |
| 综合后估算 Fmax | 712.892 MHz | 724.577 MHz |
| 820 MHz 数据 setup slack | −0.184 ns | −0.161 ns |
| 700 MHz 数据 setup slack | +0.025 ns | +0.048 ns |
| 700 MHz 数据 hold slack | +0.057 ns | +0.057 ns |
| 700 MHz 门控 setup / hold slack | +0.166 / +0.103 ns | +0.201 / +0.097 ns |
| DFF / 数据锁存器 / 门控单元 | 8,410 / 2,048 / 477 | 相同 |

面积增加 43.624 μm²（0.060%），700 MHz 的四类时序检查全部通过。820 MHz 仍失败，
其门控 setup slack 也为负（−0.008 ns）；724.577 MHz 是工具估算值。本轮 700 MHz
检查使用与 820 MHz 完全相同的网表，仅改变时钟约束，没有新增时序例外。
上次测量后还做过模块改名及文件清单整理，因此这些差值表示两次最终映射结果的差别，
不能全部归因于新增的异常阻塞条件。

## 复现与证据

从面试工作树根目录执行，综合输出使用新目录：

```bash
export NPC_HOME="$PWD/npc" AM_HOME="$PWD/abstract-machine" NEMU_HOME="$PWD/nemu"
make -C npc git_commit= NPC_CONFIG=rv32-baseline test-precise-exception
make -C npc git_commit= NPC_CONFIG=rv32-baseline sta-reset \
  STA_FREQUENCY_MHZ=820 STA_SYNTH_STRATEGY='DELAY 0' \
  STA_TOOL_DIR="$PWD/npc/result/sta/rv32-interrupt-20260906/toolflow" \
  STA_OUTPUT_ROOT="$PWD/npc/result/performance/precise-exception-recheck/sta"
```

[功能证据](../../result/verification/precise-exception-fix-20260919/)保存修复前失败、修复后
32 项结果、各回归命令和源码哈希。[综合证据](../../result/performance/rv32-precise-exception-20260919/)
保存工具哈希、完整命令、单元统计、时序报告和 `comparison.json`；700 MHz 的命令及
网表哈希在对应目录的 `command.json`。50 个综合输入与经过测试的当前 RTL 逐字节一致。
提交保留这些小型证据；完整构建日志、冻结源码和网表保留在本地实验目录。
