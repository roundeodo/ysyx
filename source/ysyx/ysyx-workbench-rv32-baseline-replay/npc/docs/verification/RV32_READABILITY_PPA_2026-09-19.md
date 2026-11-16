# RV32 整理后的综合与性能复测

对象：`rv32-interview-20260911` 工作树，`d8bb7dd` 加前端重写、完整目录整理及本次修复。
基线为 [2026-09-15 前端重写结果](RV32_FRONTEND_REWRITE_2026-09-15.md)。源码快照、工具配置、
原始日志和比较脚本保存于 [本次实验目录](../../result/performance/rv32-readability-ppa-20260919/)。

## 相同条件下的结果

两次均使用 `rv32-baseline`：I-cache 256 B / 1 路、D-cache 256 B / 2 路、cacheline 16 B，
BHT 16 项、BTB 16 项 / 2 路、RAS 4 项。综合沿用冻结的 Yosys/Slang、iEDA 工具流程、
NanGate45 typical 库、820 MHz 约束和 `DELAY 0` 策略。
面积包含 CPU 核及复位控制/缓冲，不包含 SoC；时序为综合后估算，尚无布局布线寄生参数。

| 指标 | 整理前 | 整理后 |
| --- | ---: | ---: |
| 标准单元面积 | 73,030.034 μm² | 73,037.748 μm² |
| 估算 Fmax | 707.409 MHz | 712.892 MHz |
| 820 MHz 最差 setup slack | −0.195 ns | −0.184 ns |
| 700 MHz 最差 setup slack | +0.014 ns | +0.025 ns |
| DFF / 数据锁存器 / 门控单元 | 8,410 / 2,048 / 477 | 相同 |
| microbench test 总周期 | 4,498,243 | 相同 |
| 同一窗口退休指令 | 763,521 | 相同 |
| Total IPC | 0.169737606 | 相同 |
| 原生定时器 Total 时间 | 6.426 ms | 相同 |
| Scored IPC / 定时器时间 | 0.211616786 / 2.904 ms | 相同 |

面积增加 7.714 μm²（0.0106%），估算频率提高 0.775%。门级统计显示组合门型和缓冲器配比
变化，保存状态的单元数量不变。没有测到短测性能退化，因此保留当前结构。
820 MHz 仍不满足时序；关键路径仍是 fetch buffer 读指针经过译码、操作数选择到 ID/EX。
对同一份网表降低约束至 700 MHz 后，setup / hold / 门控 setup / 门控 hold 的最差余量
分别为 +0.025 / +0.057 / +0.166 / +0.103 ns，全部通过；没有重新综合或增加时序例外。

microbench 使用 700 MHz CPU、100 MHz 等效外设延迟和 1 MHz `mtime`。
程序镜像、ELF、编译器和非 RTL 输入与基线一致。IPC 用原生计时窗口内的退休指令差除以
周期差计算，观察器不向程序插入指令。10 项测试通过，全部 25 条采样记录相同；缓存、
分支预测和停顿统计也相同。本次运行的是 **test，不是 train**，不据此推算 train 用时。

## 发现并修复的问题

- 冒险控制模块在声明前使用 `older_instruction_present`，导致 Slang 综合失败。
  已把完整赋值移到声明之后；表达式与时序行为不变。修复后的综合检查报告 0 个问题，
  复位缓冲结构等价和连通性检查通过；流水控制测试通过，包含 991 次取指队列交付检查。
- 性能报告的两处 `16-entry` / `64-entry` 说明被机械重命名为 `entry_index`，已恢复文字。
  除这两处显示文字外，本次与基线的完整仿真日志相同。

[编码规范](../development/NAMING_GUIDE.md)已补充先声明后使用、显示文字按语义修改，
以及整目录重排后必须用实际综合前端检查。Verilator 的 `SYNTHESIS` lint 不能代替综合。

基准仿真绑定的是上述两项修复前的源码；修复仅移动完整赋值和更正显示字符串，差异保存在
`rtl-fixes.patch`。综合使用的 54 个冻结源文件与修复后的综合输入逐字节一致。
旧快照和首次失败日志保留，没有改写历史测量。

## 复现

从面试工作树根目录执行，输出目录必须使用新名称：

```bash
export NPC_HOME="$PWD/npc" AM_HOME="$PWD/abstract-machine" NEMU_HOME="$PWD/nemu"
make -C npc git_commit= NPC_CONFIG=rv32-baseline sta-reset \
  STA_FREQUENCY_MHZ=820 STA_SYNTH_STRATEGY='DELAY 0' \
  STA_TOOL_DIR="$PWD/npc/result/sta/rv32-interrupt-20260906/toolflow" \
  STA_OUTPUT_ROOT="$PWD/npc/result/performance/readability-recheck/sta"
python3 npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 700 \
  --output npc/result/performance/readability-recheck/microbench-test-700
```

本次完整综合命令记录在 `synthesis-command.json`；`compare.py` 读取两版原始报告，生成
`comparison.json`，不以文档中的手写数字作为比较输入。同网表 700 MHz STA 的命令和
网表哈希保存在 `sta-current/riscv32_core_reset_boundary-700MHz-buffered/command.json`。
