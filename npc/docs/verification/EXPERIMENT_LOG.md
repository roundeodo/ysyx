# 验证记录与当前待办

状态：保留历史结果；当前能力与待办按源码核对

文档更新：2026-09-05

2026-09-05 先完成文档与源码核对，随后进行 RTL 目录、命名与排版整理。两次工作的范围
分别见第 7 节和第 10 节。下方 2026-08-26 的结果保留为历史记录，不与本次结果合并。

## 1. 历史清理说明（2026-08-26）

旧记录混合了已废弃RV32配置、RV64迁移配置、不同cache容量、不同总线延迟和多个综合约束，
其中许多数值不能直接比较。本文件不再保留这些排行榜。需要追溯历史时使用Git提交，不把
过期数据继续作为当前架构依据。

当前唯一构建配置为 `rv64-edge-ai`。名称不表示已经支持 AI 推理。后续每项测量应记录
自己的 RTL、软件和工具约束；比较版本时明确改动变量，控制其他条件。

## 2. 当前回归范围

需要持续验证的功能包括：

- RV64I 整数运算，以及 W 类指令产生 32 位结果再符号扩展到 64 位的行为；
- Zicsr、Zifencei、同步异常入口和 `mret`；机器态中断须接通后新增测试；
- `valid/ready` 流水级、相关与前递、load 后使用的停顿，以及错误路径清除；
- I-cache 命中、缺失、突发回填、所需字提前返回和失效；
- D-cache 读写、字节使能、脏行写回、回填、维护和 uncached 路由；
- BHT/BTB/RAS 预测、重定向和旧 epoch 响应丢弃；
- 64 位 core AXI4 与外部 32 位 ysyxSoC 数据接口转换。

## 3. 快速回归

在`ysyx-workbench/npc`目录执行：

```bash
make test-config
make test-idu
make test-exu
make test-lsu
make test-pipeline
make test-uncached
make test-dcache
make test-core-merge
make test-soc-width-converter
make test-privileged
make test-axi-delayer
make lint-npc
```

2026-08-26完成RV64主线清理后已验证：

- `test-config`、`test-idu`、`test-exu`、`test-lsu`和`test-pipeline`通过；
- `test-uncached`、`test-dcache`、`test-core-merge`和`test-soc-width-converter`通过；
- `test-privileged`、`test-axi-delayer`、`cachesim-test`和`branchsim-test`通过；
- `lint-npc`通过，仅保留未使用字段等非致命告警；
- standalone RV64仿真器构建成功，`dummy-riscv64-npc.bin`命中good trap。

这组历史结果只覆盖当时运行的检查，不作为正式性能或 PPA 基线。特别是 `test-privileged`
通过不能证明整核响应中断，因为当前中断输入、待处理状态和接受路径尚未接通。

当前 RV64 集成回归入口：

```bash
make regression-rv64
```

该目标运行其依赖的配置测试、lint、构建和指定 ISA 程序，不代表覆盖所有 RV64 扩展。
当前 Makefile 没有在该目标中自动运行 `test-soc-width-converter`、`test-axi-delayer`、
`cachesim-test` 或 `branchsim-test`；涉及这些部分时需另外运行对应命令。

正式记录前运行代表程序并启用 DiffTest。将 `IMG` 替换为实际镜像路径，并确认参考模型已构建：

```bash
make sim-difftest IMG=/path/to/rv64-image.bin REF=../nemu/build/riscv64-nemu-interpreter-so
```

## 4. 性能模型回归

以下模型保留并作为工程基础设施维护：

```bash
make cachesim-test
make branchsim-test
make test-axi-delayer
```

配置比较命令见 [缓存配置比较方法](CACHE_DESIGN_SPACE_EXPLORATION.md) 和
[分支与跳转预测设计](../microarchitecture/BRANCH_PREDICTION_DESIGN_RECORD.md)。

## 5. 待建立的基线表

在声明范围的功能回归通过后，按下表追加实测结果。没有命令输出的项目写“未测”，
不填写估算值。每行附完整配置、输入、命令和原始输出路径；未提交版本另存补丁或源码
快照及校验值，仅有 commit 不能标识当前有修改的工作区。

| commit | workload | retired | cycles | IPC | I$ MPKI | D$ MPKI | branch MPKI | Fmax | area |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 待测 | RV64 MicroBench test | - | - | - | - | - | - | - | - |

## 6. 分析规则

1. 按停顿事件区分取指不足、操作数相关、控制恢复、LSU 等待与缓存缺失。事件可能同拍
   发生；未定义互斥分类时不能直接相加，也不能把其总和当成全部周期。
2. 性能优化先定位瓶颈；为学习或实现新功能增加结构时，先说明机制目标与验证方法。
3. 模型用于预测趋势，RTL计数器用于确认真实收益。
4. 每个版本的面积、时序与周期对应自己的 RTL；不使用旧面积或旧频率解释新 RTL。
5. M1～M3 先使用普通程序与定向测试；AI 负载和系统能耗在应用阶段再评估。

## 7. 2026-09-05 源码核对发现

以下是前一次文档核对发现的限制。后续命名整理没有改变这些硬件行为；验证入口的变化
另行记录，不能据此推断限制已经解决。

| 项目 | 源码中的情况 | 后续动作 |
| --- | --- | --- |
| 机器态中断 | `riscv_core` 无中断输入；CSR 的 `mip` 固定读零；commit 的 `trap_is_interrupt` 固定为零 | 接通中断源、状态与接受路径，再做整核中断测试 |
| `fence.i` 维护错误 | D-cache 输出错误标志，core 仅用仿真断言检查 | 明确并实现硬件错误处理，再注入写回失败验证 |
| 物理地址 | `PADDR_WIDTH` 与 `MEM_AXI_ADDR_WIDTH` 均为 32 | 记录当前 4 GiB 地址空间限制，应用需要更大内存时再扩展 |
| I-cache 提前返回 | 从行首进行 4 B 窄传输，所需字到达即返回；缺失期间仍阻塞新查找 | 区分提前返回、关键字优先传输和缺失期间命中，分别测试 |
| 缓存模型 | 模型采用 LRU，RTL 当前采用轮转替换 | 比较时注明策略；按每次目标缺失分类 3C |
| 形式验证 | 前一次检查发现旧 `YSYX_RV32_BASELINE` 标记；本次已移除，并发现测试代码与当前模块端口不一致 | 按当前接口更新连接及性质，重新运行；本次失败结果见第 10 节 |

相关源码：
[core](../../vsrc/riscv/core/riscv_core.sv)、
[CSR](../../vsrc/riscv/core/riscv_csr_file.sv)、
[commit](../../vsrc/riscv/core/riscv_commit.sv)、
[配置](../../vsrc/riscv/common/riscv_config_pkg.sv)、
[I-cache](../../vsrc/riscv/core/frontend/riscv_icache.sv)、
[缓存模型](../../tools/cachesim/cachesim.cpp)。

## 8. 形式验证范围

当前入口是 `make formal-pipeline`，使用
[`riscv_pipeline_control.sby`](../../tests/formal/riscv_pipeline_control.sby) 和
[`riscv_pipeline_control_formal.sv`](../../tests/formal/riscv_pipeline_control_formal.sv)。
配置采用 BMC 模式、深度 20，检查取指缓冲顺序与冒险控制性质；不是整核或无界证明。

实际宽度由 `riscv_config_pkg` 定义。旧 RV32 宏名已移除，`.gitignore` 也已允许保存
`.sby` 文件。2026-09-05 运行时，Yosys 的 slang 前端报告冒险控制器的多处端口不存在，
尚未进入求解阶段。改名前快照在同一工具环境下报告相同的 7 个端口错误。

例如测试仍连接 `execute_uop_valid_i`，当前模块接口已经使用
`execute_instruction_present_i` 等更明确的条件。不能只替换端口拼写就宣称性质仍正确；
需要核对各输入的含义、约束和断言，再运行验证。

## 9. 当前阶段使用哪些程序

| 目的 | 可使用的程序或序列 |
| --- | --- |
| 指令语义 | RV64 指令定向测试、声明范围内的 cpu-tests 与 DiffTest |
| 前递与相关 | 连续依赖运算、同寄存器多次写入、load 后使用、独立运算 |
| 控制流 | 循环、连续分支、调用返回、间接跳转与异常返回 |
| 缓存与总线 | 不同工作集、步长和冲突地址，脏行替换，反压与错误注入 |
| 乱序机制 | 老指令等待时让年轻独立指令执行，检查执行顺序与退休顺序 |
| 多发射 | 同周期相关、资源争用、多个完成结果与提交边界异常 |

表中程序类型是测试计划，不表示每一项已有可运行程序。M1～M3 不以运行完整 AI 模型为条件。

## 10. 2026-09-05 RTL 命名与排版整理

### 改动和配置

设计目录改为 `npc/vsrc/riscv`，设计模块和 package 前缀改为 `riscv_`，同步构建、测试、
平台与文档引用。修正部分数组名称和过期注释，按现有格式器整理代码。格式器自身改为保留
Verible 给出的续行缩进，避免长左值把后续表达式推得过远。

本次没有修改处理器的运算、状态转移或握手逻辑。对照修改前快照，55 个设计 HDL 文件
及 10 个随之重命名的测试 HDL 文件，在忽略注释、空白并应用明确的标识符改名表后，
代码标记序列一致。该检查用于确认整理范围，不替代功能验证。

运行配置为 `PROJECT=riscv NPC_CONFIG=rv64-edge-ai`：XLEN=64，物理地址 32 位，
I-cache 和 D-cache 各 4 KiB、2 路、64 B 行；BHT 16 项、BTB 16 项/2 路、RAS 4 项，
`NPC_SDRAM_NATIVE_READ_BURST=1`。Verilator 版本为 `5.043 devel rev v5.042-244-g4080284e5`。

### 实际结果

| 检查 | 结果与限制 |
| --- | --- |
| 第 3 节列出的 11 个定向测试 | 全部通过；包括配置、IDU、EXU、LSU、流水控制、uncached、D-cache、I/D 仲裁、SoC 位宽转换、CSR/提交/PMU 和 AXI 延迟器 |
| `make lint-npc` | 返回成功；仍有空端口连接、未使用字段和参数告警 |
| `make -C ../ysyxSoC verilog`、`make lint-soc` | 生成与展开成功；仍有时标、位宽、未使用信号及组合环等告警，不能记为“零告警”或完成时序检查 |
| `make build-npc` | standalone 仿真器构建成功；DPI 层次引用可以编译 |
| `make regression-rv64-isa` | 35 个程序中 34 个通过；`csr-trap` 在异常后的 PC 比对失败，整项回归失败 |
| `make sim-npc IMG=../am-kernels/tests/cpu-tests/build/csr-trap-riscv64-npc.bin` | 关闭 DiffTest 时到达 good trap；不能据此替代失败的逐指令比对 |
| 修改前源码重新构建后运行同一 `csr-trap` 镜像与参考模型 | 复现相同 PC 比对错误，说明该问题在本次整理前已存在 |
| `make formal-pipeline` | 编译阶段失败；旧测试连接了当前模块不存在的 7 个端口，改名前快照也报告相同错误，未进入 BMC 求解 |
| 代码与文档检查 | HDL 标记对比通过；格式器的嵌套续行与空白检查通过；当前文档的本地链接和两份 filelist 路径有效 |

ISA 回归首次启动还发现软件入口使用 `rv64-sequential`，与 NPC 接受的配置名不一致。
已将 `abstract-machine/scripts/riscv64-npc.mk` 与当前配置统一，并在 ISA 回归入口显式传递
`NPC_CONFIG`。修正后得到上表的 34/35 结果。

`csr-trap` 的具体差异发生在 `0x80000070` 的 `ecall` 之后：DUT 报告下一 PC 为
`0x80000074`，参考模型为异常入口 `0x80000010`。下一步应检查提交记录、DPI 采样与
重定向的时序关系，并继续覆盖 `mret`；当前证据不足以宣称整个异常验证已完成。

### 证据与后续工作

本次工作区已有未提交修改，不能只用 commit 标识。整理前后的相关源码快照、重命名表、
日志、测试镜像和参考模型保存在
[`npc/result/verification/rtl-naming-20260905`](../../result/verification/rtl-naming-20260905)，
其中 `SHA256SUMS` 用于核对文件内容。历史验证记录和原有实验输出保留。

M1 先定位并修复上述 DiffTest 不一致，同步形式验证接口与性质，再处理既有中断和缓存维护
错误待办。本次未运行新的综合、STA 或功耗分析，不产生新的性能或 PPA 结论。

## 11. 2026-09-05 模块设计、旁路与可维护性检查

本次检查结论见 [RTL 设计检查](../architecture/RTL_DESIGN_REVIEW.md)。生产 RTL 和原有
测试未修改；对全部 55 个 HDL 文件记录哈希，并重点检查数据前递、缓存反压、缺失事务
及错误恢复。另从现有 `riscv_dcache_tb.sv` 派生检查用例，保存于独立结果目录。

构建沿用 `make -n -B test-dcache git_commit=` 展开的 Verilator 命令，修改测试顶层与
输出目录，并使用 `-j 2`。配置为 XLEN=64、D-cache 4 KiB/2 路/64 B 行，Verilator 为
`5.043 devel rev v5.042-244-g4080284e5`。完整宏参数与文件列表保存在 `build-command.json`。

| 用例 | 实际结果 | 说明 |
| --- | --- | --- |
| `+review_case=0` | 通过，退出码 0 | 保留原 D-cache 定向序列，包括正常写回与回填重叠检查 |
| `+review_case=1` | 断言失败，退出码 1 | 缓存命中响应被反压，输入请求无效且地址改变后，原响应数据从 `5d5c5f5e59585b5a` 变成 `5554575651505352` |
| `+review_case=2` | 断言失败，退出码 1 | 下层丢弃写回并返回错误；当前缺失报告 fault 后，再读旧地址得到旧内存值，而非已完成 store 的 `8877665544332211` |

两个失败是本次复现的待修复缺陷，不能计为功能测试通过。用例 1 检查缓存模块自己的
反压约定；当前 LSU 保留请求地址的行为可能掩盖问题。用例 2 检查报告写回错误后继续
服务时的脏数据保存；当前实现没有恢复或明确停止正常服务的流程。

证据目录：[module-review-20260905](../../result/verification/module-review-20260905)。
其中保存派生测试、原测试、55 个 HDL 文件的源码快照、构建参数、日志与 `SHA256SUMS`。
`reproduce.py` 使用快照在新目录重建并运行三项用例，不依赖后来修改过的生产 RTL。
已实际运行快照重建，构建成功，三项退出码仍分别为 0、1、1；日志另存于证据目录的
`snapshot-rebuild/`。文档本地链接、空白检查与 55 个 RTL 文件未改变的哈希检查均通过。

从 `npc` 目录重跑现有二进制：

```bash
result/verification/module-review-20260905/dcache_review +review_case=0
result/verification/module-review-20260905/dcache_review +review_case=1
result/verification/module-review-20260905/dcache_review +review_case=2
```

从已保存源码重新构建并运行：

```bash
python3 result/verification/module-review-20260905/reproduce.py --output /tmp/npc-dcache-review-rebuild
```

本次未重新运行完整 ISA、形式验证、综合、STA 或功耗分析。第 10 节的 `csr-trap` 与
形式验证失败仍是待办。本次也未测量查询旁路、LSU 周转等候选的性能收益。

## 12. 2026-09-05 RTL 修复、冗余清理与回归

### 改动与配置

本轮修复第 11 节复现的两个 D-cache 缺陷，以及第 10 节的异常 PC 调试采样和形式验证
接口问题。具体改动见 [RTL 修复与清理记录](../architecture/RTL_CLEANUP_RECORD.md)。

D-cache 在反压期间保持已接收请求的应答；脏行写回失败后从原缓冲恢复整行数据和元数据。
AXI 适配器共用 miss unit 的回写数据，删除第二份整行寄存器。FENCE.I 清理失败时保持
取指阻塞，撤下请求一拍后重试；清理成功才允许 I-cache 失效。持续错误仍会持续阻塞，
当前没有重试上限或软件错误报告机制。

其余修改包括删除 I-cache 不可达选择路径、压缩预测训练包、共用字节合并和统计函数、
删除未使用类型及未实例化模块，并按功能整理声明、状态更新和注释。保留已有数据前递、
原请求的 I-cache 所需字提前返回，以及 D-cache 写回与回填重叠。

配置与第 10 节相同：`PROJECT=riscv NPC_CONFIG=rv64-edge-ai`，XLEN=64、物理地址 32 位，
I/D-cache 各 4 KiB、2 路、64 B 行，BHT 16 项、BTB 16 项/2 路、RAS 4 项。配置名不代表
已实现 AI 扩展。Verilator 为 `5.043 devel rev v5.042-244-g4080284e5`。

### 功能结果

| 检查 | 实际结果与边界 |
| --- | --- |
| 原检查用例 `review_case=0/1/2` | 使用修复后的 RTL 重新构建，全部通过；保留原失败日志用于对照 |
| 11 个定向测试 | 配置、IDU、EXU、LSU、流水控制、uncached、D-cache、I/D 仲裁、SoC 位宽转换、CSR/提交/PMU、AXI 延迟器全部通过 |
| 扩充后的 D-cache 测试 | 反压时无效地址变化、有效下一请求等待、多字节写读旁路、同拍脏位前递、整行错误恢复和维护重试通过 |
| AXI 写数据停顿 | 在脏行替换和维护重试中插入连续 W 反压，共用行缓冲的数据稳定性检查通过 |
| B/R 错误组合 | B 错误、R 错误、双向错误分别覆盖 B 先完成、R 先完成及同拍完成，共 9 种场景；恢复后核对整行数据并重试清理 |
| FENCE.I 维护错误 | 连续三次清理写回失败期间保持阻塞，随后成功清理并等待 I-cache 失效完成；这是控制器与 D-cache 的集成测试 |
| `make regression-rv64-isa` | 35/35 通过，包含此前失败的 `csr-trap`；不等于覆盖所有特权行为或外部中断 |
| `make formal-pipeline` | PASS；深度 20 的有界检查，范围为取指队列、前递选择和流水控制，不是整核无界证明 |
| `make lint-npc`、`make lint-soc` | 均返回成功；位宽转换器拆开读通路的正反向计算后，两处既有 UNOPTFLAT 告警消失。其他告警仍存在，不能记为零告警 |
| 转换器等价检查 | 输出过程拆分前后 1327 个等价点全部证明；Yosys `equiv_simple`，使用 `async2sync` 后的时钟边界模型，不包含异步复位脉冲行为证明 |

从 `npc` 目录重跑本轮主要检查：

```bash
make test-config test-idu test-exu test-lsu test-pipeline test-uncached \
  test-dcache test-core-merge test-soc-width-converter test-privileged \
  test-axi-delayer lint-npc lint-soc formal-pipeline git_commit=
make regression-rv64-isa git_commit=
```

SoC 原有两处组合环告警分别指向 `_axi4delay_delayer_out_arvalid` 和 `io_master_arready`。
位宽转换器原先在一个组合过程中计算下游 AR/RREADY 与上游 READY/R 数据，工具把两种
方向的依赖合并。按方向拆分过程后告警消失，等价检查及定向测试通过；未屏蔽告警，
也没有增加寄存器或握手周期。相关脚本与日志为 `converter-output-equivalence.ys/.log`
和 `converter-final.log`。这是本轮核心回归结束后对平台转换器的单独整理。

### 同程序执行周期比较

分别构建修改前快照与修改后 RTL，运行相同镜像。以下采用 C++ 仿真器报告的总周期和
退休计数，包含它的程序结束统计；不要与硬件 PMU 的计数直接混用。前后均关闭 DiffTest
进行本表测量，修改后另有上述 35/35 的 DiffTest 回归。

| 程序 | 修改前周期 | 修改后周期 | 前后退休数 |
| --- | ---: | ---: | ---: |
| load-store | 1135 | 1135 | 377 |
| matrix-mul | 362041 | 362041 | 229127 |
| string | 3583 | 3583 | 1645 |
| quick-sort | 6714 | 6714 | 3156 |

四个程序均正常结束。结果支持这些负载的周期数未退化，不代表所有工作负载都相同，
也不代表更高的最高工作频率。镜像哈希、命令和计数保存在 `benchmark-results.json`。

### 面积与时序

前后采用同一 Nangate45 库、300 MHz 约束、`DELAY 0` 策略及完整默认缓存配置，顶层为
`riscv_core`，使用 `constr/riscv_core.sdc`。缓存按现有 RTL 映射到标准单元，未替换为
SRAM 宏；没有进行布局布线或功耗分析。完整命令保存为 `sta-before-command.json` 和
`sta-after-command.json`。

对回写适配器另做独立综合，以量化重复缓冲删除的局部效果。顶层为
`riscv_dcache_line_axi4_master`，库、时钟和 I/O 约束与上面一致：

| 回写适配器指标 | 修改前 | 修改后 |
| --- | ---: | ---: |
| 标准单元面积（µm²） | 3995.054 | 1670.480 |
| 触发器数量（含复位/置位型，不含时钟门控单元） | 598 | 86 |
| 最差 setup 余量（ns，报告精度） | 1.717 | 1.719 |

该模块面积减少约 58.2%，少了 512 个触发器；setup 余量在报告精度下基本相同。
这是独立适配器的结果，不等于整核面积减少 58.2%，也不说明整核达到某个最高频率。
数据与报告见 `writeback-area-comparison.json`、`sta-writeback-before/`、`sta-writeback-after/`。

完整默认配置的两次全核测量未完成：修改前流程运行约 102.6 分钟，停留在 ABC 工艺映射；
修改后流程运行约 68.9 分钟，停留在存储写优先级优化。已核对两者持续占用 CPU，随后停止
本轮启动的测量进程并保留日志，记录见 `full-core-ppa-stop.json`。这不是综合或 STA 通过，
没有整核映射面积、时序或功耗结论；上面的局部结果不能替代它们。后续应先解决全容量
阵列综合的耗时问题，再完成同配置整核比较。

### 证据

[rtl-cleanup-20260905](../../result/verification/rtl-cleanup-20260905) 保存修改前后的源码与
测试快照、输入哈希、构建命令和日志。主要结果为 `regression-final.log`、`isa-final.log`、
`dcache-final-backpressure.log`、`benchmark-results.json` 及前后综合结果目录。
工作区原有未提交内容予以保留，不把当前 Git commit 当作本轮实际源码版本。
