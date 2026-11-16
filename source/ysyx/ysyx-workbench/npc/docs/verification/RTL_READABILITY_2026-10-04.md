# RV64 电路顺序与命名检查

本轮检查 `vsrc/riscv/core`、`system` 与共享类型的代码组织，重点复核后来加入的
Issue、scoreboard、ID/EX 和乘除单元。目标是按实际数据流阅读 RTL，保留原电路行为、
寄存边界、握手条件和异常优先级；不把源码先后顺序当作硬件串行执行顺序。

## 修改前发现

- Issue 的 `pending_writer_present` 未说明它指 ID/EX 内尚未发射的写者。
- 等待接口的 `operand_index` 实际为生产者 scoreboard 槽号，`operand_source` 为
  完成端口类型；应与寄存器 rs1/rs2 编号及操作数数值区分。
- EXU 的 `execute_rs1_value`、`execute_rs2_value` 实际已经经过操作数选择，可能是
  PC、立即数或前递值，不能再把它们统称为寄存器读值。
- ID/EX 的输出与生产者分类穿插在时序块之间；scoreboard 的源查询放在条目更新之后；
  core 的预测器实例排在取指缓冲之后，均增加逆向查找。
- 乘法流水的通用 `index_array_q`、`format_array_q` 缺少对象说明；除法计数宽度
  `COUNT_WIDTH` 未说明是迭代位数计数器。
- 模块总览仍写 8 项 scoreboard，与当前 4 项配置不一致。

## 本轮处理与验收

接口名称同步更新到父模块和单元测试；独立连续赋值、实例和过程块按功能移动，
不交换过程块内部具有优先级的语句。三段式状态机仍按输出、下一值、时序更新排列；
组合单元和简单流水寄存器按其真实结构组织，不增加状态机。

本轮扫描 43 个 core、8 个 system 和 5 个 common 文件的模块职责、声明、组合块及
时序块排列；深入修改 7 个 RTL 文件，同步 4 个测试文件。扫描不等于逐模块功能证明。
缓存、总线状态机大多已有输出、下一值、更新分组，未为了统一外观强行重排。
CSR 的异常入口、mret、软件写入共用明确优先级，保留其集中更新，不拆成容易漏掉
优先级的多份控制。历史模块及实验继续保留。

| 修改模块 | 当前阅读顺序或名称修正 |
| --- | --- |
| core | 预测器与 IFU 接口相邻，随后是 I-cache、取指缓冲、译码、发射、执行/访存、提交与恢复 |
| Issue | 当前 EX 写者匹配 → 源值与等待判断 → 串行化与发射授权；`pending_writer` 改为 `execute_writer` |
| ID/EX | 完成端口选择与索引匹配 → 操作数前递及就绪判断 → 等待位、载荷和有效状态更新 |
| scoreboard | 完成接口 → 分配/提交读口 → 源查询 → 指针及每槽状态更新；分配和提交事件名带 `handshake` |
| EXU | 整数/分支、乘除、CSR、AGU/LSU、普通结果选择与控制反馈分别组织 |
| MUL | 部分积 → 压缩 → 分半求和与返回选择；索引和格式数组带具体对象名称 |
| DIV | 保留输出 → 下一状态 → 更新顺序；计数宽度改称 `ITERATION_COUNT_WIDTH` |

完成的检查：

- 11 个改动文件经过重命名归一后，代码标记计数一致；所有 `always_comb`、`always_ff`
  和 `always_latch` 的完整过程体一致，确认未交换块内语句。该检查不冒充形式等价证明。
- `test-operand-wait`：526 项通过；`test-scoreboard`：636 项通过。
- `test-scoreboard-core`：7 个场景通过。
- `test-execution-units`：ALU 12816 项、分支 7168 项；乘法 4005 个请求、除法 6408 个请求，
  包含取消与反压；IDU/EXU 完成 10413 个事务，延迟检查通过。
- `test-pipeline`：RV64 控制回归通过；取指队列检查 1012 个输出。
- 整 SoC `lint` 命令退出成功。与修改前源码相比，警告类别、数量和归一后的诊断内容
  一致，包括已有的 9 项 UNOPTFLAT；并非零警告验收。对照见
  [lint 记录](data/rtl-readability-2026-10-04/lint-comparison.json)。

命令：`make git_commit= test-operand-wait test-scoreboard test-scoreboard-core test-execution-units test-pipeline lint`。
源码哈希、过程体核对结果与本轮独立补丁见
[数据目录](data/rtl-readability-2026-10-04/source-audit.json)。
本轮不运行 train，不作 IPC、面积或频率改善声明，也没有重新执行全 SoC 程序或综合时序。

后续前端、访存与系统接口的检查见[第二轮复核](RTL_READABILITY_FOLLOWUP_2026-10-04.md)，其修改与验证证据单独保存。
