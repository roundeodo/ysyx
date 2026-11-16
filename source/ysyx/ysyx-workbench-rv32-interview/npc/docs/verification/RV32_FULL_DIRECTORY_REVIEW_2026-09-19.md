# RV32 完整目录代码检查

分支 `rv32-interview-20260911`，工作树 `ysyx-workbench-rv32-interview`，HEAD `d8bb7dd`。
本记录补齐[前次整理](RV32_READABILITY_2026-09-16.md)的范围；修改尚未提交。

## 范围与结果

按实际目录清点 `npc/vsrc/riscv32`，共 **67 个文件**：63 个 `.sv`、1 个 `.v`、
1 个 `.svh` 和 2 个 filelist。
本轮补改 **39 个文件**；连同前面已有修改，工作树中 **66 个文件已调整**，
`system/riscv32_reset_controller.sv` 检查后保留原样：其异步复位、两级同步和下降沿释放已清楚。

[逐文件清单](../../result/readability/rv32-all-20260919/audit.json)记录全部文件的电路检查要点、
本轮处理结果和 SHA256，包括实验模块、DPI 头文件及未被当前核实例化的历史模块。

## 补充修改

- 当拍事件改为 `_event`，握手使用 `_handshake`；已保存的历史仍使用 `_occurred_q`。
  数组、有效位集合和操作数选择分别使用 `_array`、`_vector`、`select`，相关连接与测试同步。
- 性能监视器按状态归属组织声明、辅助函数和更新逻辑。周期/停顿、指令类别、静态预测统计
  分为独立时序块；同一组状态的更新顺序保持不变，报告函数放在报告附近。
- 三个实验模块补齐端口语义、组合电路说明和排版。DPI 说明采样时刻与固定字段索引，
  保留宿主接口；配置和公共类型清楚标出未实例化的实验内容，纠正过时的预测与地址说明。
- [编码规范](../development/NAMING_GUIDE.md)明确“整个目录”的验收范围，格式化不能代替
  逐文件检查。模块说明继续维护在现有设计记录中，不为每个文件重复新建说明。

本轮没有增加流水级或修改握手时序。寄存器堆读口、cache store 旁路、前递和状态机行为保留。
文件编排遵循实际数据流；状态机按组合输出、下一状态、时序更新排列。

## 按流水线功能组织目录

将 21 个平铺模块移入 `core/frontend`、`decode`、`execute`、`memory`、`writeback`、
`control`，`core` 根目录只保留整核连接。目录职责见[源码目录说明](../microarchitecture/README.md)。
Makefile、两份 filelist、当前前端测试脚本和文档链接同步更新。

`path-map.json` 记录旧路径到新路径，`verify_layout.py` 核对 67 个文件的一一对应：
65 个 RTL/头文件的内容与已通过回归的版本逐字节相同，2 个 filelist 仅替换路径、保持顺序。
历史实验记录和源码快照保留旧路径，按各自版本读取。
移动后重新通过 NPC/SoC lint、综合配置 lint 和取指测试；构建入口检查通过，92 处当前
文档源码链接有效。证据为 `layout-check.json`、`layout-lint-fetch.log` 和 `layout-lint-synthesis.log`。

## 验证

证据目录：`npc/result/readability/rv32-all-20260919/`，保存修改前后源码、命名映射、逐文件记录和日志。

- `check_structure.py`：按 RV32 配置预处理并启用仿真模块与 SVA，67/67 通过。
  61 个文件语法树保持一致（允许显式重命名）；3 个只重排
  完整模块项；2 个 filelist 顺序不变；监视器在显式拆分独立计数器后模块项一致。
  检查不排序过程块内部语句，也不代表原设计全部行为已经形式化证明。
- 监视器前后对照：5,000 周期、83 组保存状态（含两张 BHT 数组）一致。
- 三个实验模块前后对照：16 种七段码输入、64 种移位输入全部覆盖；ALU 比较 65,536 组向量。
- 被动测量分析脚本：5 项通过。

| 回归或检查 | 结果 | 证据 |
| --- | --- | --- |
| RV32 配置、译码、EXU、LSU、流水控制、uncached、D-cache、I/D 仲裁、特权/PMU | 9 个入口通过 | `rv32-unit.log` |
| RV32 整核 DiffTest | 35/35 通过 | `difftest.log` |
| 定时中断：3 汇编 + 2 AM + 3 RTL | 8/8 通过 | `timer.log` |
| 预测器、IFU、I-cache | 5 配置/60,000 周期；100 次交付；13 项 cache 检查通过 | `frontend.log` |
| 被动 DPI 采样 | 21 次提交、19 条退休；窗口退休数为 9 和 3；观察器开关日志相同 | `passive-timer/report.json` |
| 历史 mcycle 窗口观察器 | 通过 | `issue-window.log` |
| RV64 共享模块的 64→32 转换、特权/PMU 和整核 lint | 通过 | `shared-rv64.log` |
| RV32 NPC / SoC lint，STA 文件清单 + SYNTHESIS lint | 通过 | `lint-final.log`、`lint-synthesis.log` |

lint 保留未使用信号、第三方 SoC 等既有告警；没有 LATCH、MULTIDRIVEN、UNOPTFLAT、
PINMISSING、IMPLICIT 或错误。首次中断构建触发脚本 300 秒超时，日志保留在
`timer-first.log`；复用已编译对象后重跑全部 8 项通过。

DPI 检查使用原 `timer_retire_boundary.S`，将链接地址和加载方式适配 standalone；
它验证采样边界和无侵入性，不作为 SoC 性能测量。

历史 `riscv32_predictor_equivalence_tb.sv` 会重放两个旧 Git 版本，因此保留旧端口名；
当前版本的预测器验证使用 `riscv32_predictor_contract_tb.sv`，已同步新命名。

整理阶段没有重测面积、STA 或 microbench train。随后已补做实际综合、STA 和 microbench
test，并修复 Slang 检出的声明顺序问题，见[后续复测](RV32_READABILITY_PPA_2026-09-19.md)。
本页的字节与语法树检查对应当时快照；后续修复差异另存，不能要求当前源码仍与旧快照完全相同。

原始结构检查脚本及结果保留在证据目录。当前版本的快速回归（从工作树根目录执行）：

```bash
export NPC_HOME="$PWD/npc" AM_HOME="$PWD/abstract-machine" NEMU_HOME="$PWD/nemu"
make -C npc git_commit= NPC_CONFIG=rv32-baseline lint-npc lint-soc test-fetch
```
