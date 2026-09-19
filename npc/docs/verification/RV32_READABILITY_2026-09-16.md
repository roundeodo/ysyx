# RV32 后端与系统代码整理验证

2026-09-16，`rv32-interview-20260911`，基于 `d8bb7dd` 和既有前端工作树改动；本轮未提交。
范围为 `vsrc/riscv32` 中前端以外的 47 个现有 SV 文件：45 个有修改，2 个保持原样，
另新增操作数准备与 FENCE.I 控制模块。实验目录和历史模块保留。

## 修改性质

- core 按数据流组织连接；操作数 mux 移到纯组合 `operand_prepare`，FENCE.I 状态与
  请求保持位移到 `fence_i_controller`。没有新增流水级、寄存状态或不同的前递优先级。
- EXU 的并行运算、D-cache 的查询/响应/clean/端口选择、PMU 的各组状态相邻组织；
  数据路由和宽度转换按组合输出、下一状态、时序更新排列，CLINT 的计数与比较值放在一起。
- 其他后端、阵列、总线、类型定义和仿真模块整理声明、列对齐、条件续行与旧注释。
  PMU 中只用于断言的重复地址检查移入 `ifndef SYNTHESIS`，未改软件可见计数行为。
- 流水线、D-cache、总线、中断说明只维护当前结构；旧内容归档，面试说明同步模块归属。

## 源码结构核对

证据目录：`npc/result/readability/rv32-rest-20260916/`。
`before-source.tar.gz` 与 `before-hashes.json` 保存整理前内容；`after-hashes.json` 覆盖最终
49 个文件；`check_structure.py` 和 `structure-check.json` 保存可重复的结构检查。

| 核对方式 | 文件数 | 结果 |
| --- | ---: | --- |
| 完整语法树一致，忽略位置与普通注释 | 37 | 通过 |
| 完整模块项一致，只调整模块内排列 | 7 | 通过 |
| 宽度转换 generate 内的完整模块项调整排列 | 1 | 通过 |
| 按实际端口连接展开两个新模块，与原 core 对照 | 1 | 通过 |
| PMU 完整模块项一致，断言专用译码改为受综合宏保护 | 1 | 通过 |

检查没有排序过程块内部的语句。它证明本轮整理保留了原有表达式和更新过程，
不等于对原设计所有行为的形式化正确性证明。

## 功能与静态检查

| 检查 | 结果 | 日志 |
| --- | --- | --- |
| RV32 配置、译码、EXU、LSU、流水控制、非缓存、D-cache、I/D 仲裁、特权/PMU | 9 个入口全部通过 | `units-rv32-final.log` |
| RV32 整核 DiffTest | 35/35 通过 | `difftest.log` |
| 定时中断：3 汇编 + 2 AM + 3 RTL | 8/8 通过 | `timer.log` |
| RV64 共享代码：64→32 转换、特权/PMU、整核 lint | 通过 | `shared-rv64.log` |
| RV32 NPC 与 SoC lint | 通过 | `lint-final.log` |
| STA 文件清单 + SYNTHESIS 宏的静态检查 | 通过 | `lint-synthesis-final.log` |

lint 仍有未使用信号/参数等告警；最终 RV32 日志中没有 LATCH、MULTIDRIVEN、UNOPTFLAT、
PINMISSING、IMPLICIT 或错误。这里的综合配置检查只做展开与 lint，没有执行综合或 STA。

测试入口纠正：首次把仅针对 64→32 转换的测试台放进 RV32 列表，触发了其 64 位 lane
断言；同一测试台在正确的 RV64 配置通过，最终 RV32 列表已移除此项。初次直接调用
STA 文件清单也因漏传配置宏/包含路径失败，改用 Makefile 的完整配置后通过。两份初始
日志保留为 `units-rv32.log` 和 `lint-synthesis.log`，不列为通过结果。

## 复现

从 `ysyx-workbench-rv32-interview` 根目录运行，`git_commit=` 禁止旧 Makefile 自动提交：

```bash
export NPC_HOME="$PWD/npc" AM_HOME="$PWD/abstract-machine" NEMU_HOME="$PWD/nemu"
make -C npc git_commit= NPC_CONFIG=rv32-baseline \
  test-config test-idu test-exu test-lsu test-pipeline test-uncached \
  test-dcache test-core-merge test-privileged
make -C npc git_commit= NPC_CONFIG=rv32-baseline test-timer-interrupt
make -C npc git_commit= NPC_CONFIG=rv32-baseline lint-npc lint-soc
make -C npc git_commit= NPC_CONFIG=rv64-sequential \
  test-soc-width-converter test-privileged lint-npc
make -C am-kernels/tests/cpu-tests git_commit= ARCH=riscv32-npc \
  NPC_CONFIG=rv32-baseline NPC_RUN_TARGET=sim-difftest \
  REF=/home/yong/ysyx/ysyx-workbench/nemu/build/riscv32-nemu-interpreter-so \
  CAPSTONE_HOME=/home/yong/ysyx/ysyx-workbench/nemu/tools/capstone/repo run
make -C npc git_commit= NPC_CONFIG=rv32-baseline \
  NPC_TOP_MODULE=riscv32_core_reset_boundary \
  RTL_FILELIST="$PWD/npc/vsrc/riscv32/filelist/filelist_sta.f" \
  VERILATOR="verilator +define+SYNTHESIS +incdir+$PWD/npc/vsrc/riscv32/sim" lint-npc
python3 npc/result/readability/rv32-rest-20260916/check_structure.py
```

本轮未重测综合面积、频率和 microbench train，不能把结构整理表述为已测得性能提升。
